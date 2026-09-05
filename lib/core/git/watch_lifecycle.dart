import 'dart:async';

import 'coalescer.dart';
import 'watch_diagnostics.dart';
import 'watch_event.dart';

/// What one [WatchArmCallback] invocation produced.
///
/// Three outcomes, deliberately distinct: a live watch source
/// ([WatchArmed]), "this transport has no watch source at all right now"
/// ([WatchUnavailable] — degrade to polling and periodically re-try), and
/// "the stream was cancelled while I was arming; I have already cleaned up
/// my partial state" ([WatchAborted] — do nothing further). Collapsing the
/// last two into one value was never possible: polling on cancel would leak
/// a timer past the stream's death, and aborting on no-tool would leave the
/// UI silently un-refreshed forever.
sealed class WatchArm {
  const WatchArm();
}

/// The source is armed and delivering events through the hooks; [teardown]
/// cancels its subscriptions/handles. Called exactly once, before any re-arm.
class WatchArmed extends WatchArm {
  const WatchArmed(this.teardown);
  final Future<void> Function() teardown;
}

/// Why an arm could not produce a live source.
///
/// The engine used to see one undifferentiated `WatchUnavailable` and answer
/// every cause with the same 3-minute recovery. They are not the same kind of
/// condition: [ceiling] is transient and resolves the instant another watcher
/// stops — it is a property of this process, not of the host — where [noTool]
/// persists until the host itself changes. 0028 H2.
enum WatchUnavailableReason {
  /// No `inotifywait`/`fswatch` on the host. Persists until the host changes.
  noTool,

  /// This process already holds its maximum concurrent watchers. Transient,
  /// and resolves the moment any watcher is released.
  ceiling,

  /// The SSH stream budget is exhausted (0024 M2). Semi-persistent.
  streamBudget,

  /// A bounded spec matched no existing paths yet. Transient — resolves as
  /// tracked files appear.
  noWatchedPaths,
}

/// No watch source is available — degrade to polling, with periodic recovery
/// retries. [reason] says which condition applied; see
/// [WatchUnavailableReason] for why the difference matters.
class WatchUnavailable extends WatchArm {
  const WatchUnavailable(this.reason);
  final WatchUnavailableReason reason;
}

/// The stream was cancelled mid-arm; the callback already tore down whatever
/// it had partially created.
class WatchAborted extends WatchArm {
  const WatchAborted();
}

/// The engine-side surface an arming callback drives events through.
class WatchHooks {
  const WatchHooks({
    required this.signalPath,
    required this.noteActivity,
    required this.scheduleRestart,
    required this.rearm,
    required this.isCancelled,
  });

  /// Report one changed path (already filtered by the caller — the engine
  /// does not apply [shouldTriggerWatch]; which paths matter is transport
  /// knowledge). Buffered into the next coalesced tick.
  final void Function(String path) signalPath;

  /// Proof the source is genuinely healthy — a real event arrived. Resets the
  /// restart budget. Deliberately NOT called by the engine when arming
  /// succeeds: a watcher that arms then dies repeatedly must still exhaust
  /// its budget and degrade to polling.
  final void Function() noteActivity;

  /// The source died (stream onDone/onError) — ask the engine to re-arm with
  /// backoff, degrading to polling once the restart budget is spent.
  final void Function() scheduleRestart;

  /// Re-arm the source deliberately, because what it should be watching has
  /// changed — NOT because it died.
  ///
  /// Distinct from [scheduleRestart] on purpose, and the difference is
  /// user-visible: a restart marks the mode `stopped` and emits a grey tick,
  /// applies `restarts * 2`s of backoff, and spends one of the restart budget
  /// that degrades to polling when exhausted. Re-arming for a legitimate
  /// reason — a bounded watch whose tracked-file set grew — must do none of
  /// those, or staging a file would flicker the watch indicator to "stopped",
  /// and three edits in new directories would drop the repo to polling for the
  /// rest of the session (0022 H5).
  final void Function() rearm;

  /// Whether the stream was cancelled — for checks between an arm callback's
  /// own awaits (the engine can only check before and after the whole call).
  final bool Function() isCancelled;
}

/// The watcher lifecycle engine shared by `RemoteWatchService` and
/// `LocalWatchService`: restart-with-backoff, degrade-to-polling, periodic
/// recovery from polling, path-buffering into coalesced [RepoWatchEvent]s,
/// and teardown. The two services used to each carry a line-for-line copy of
/// all of it (synchronized by "Mirrors RemoteWatchService" comments), and the
/// copies had already drifted once — the recovery-leaves-the-poll-timer-
/// running bug had to be fixed twice. Only the innermost "arm the source"
/// step differs by transport, so that is exactly what [arm] parameterizes.
///
/// Lifecycle semantics (unchanged from the originals):
/// - Arming failures re-try [maxRestarts] times with `restarts * 2`s backoff,
///   then degrade to polling every [pollInterval].
/// - While polling, every [recoveryInterval] the engine re-tries event-driven
///   watching ([onPollingRecoveryAttempt] first, so a service can drop caches
///   like the detected watcher tool).
/// - A restart emits an immediate `stopped` tick so the UI's watching dot
///   reflects the outage for the whole backoff window; a successful arm emits
///   an immediate `eventDriven` tick so it turns green before the first real
///   change.
/// - Up to 512 distinct changed paths ride each tick; past that the set
///   degrades to "unknown scope" (empty), which consumers treat as refresh
///   everything.
Stream<RepoWatchEvent> watchLifecycle({
  required Future<WatchArm> Function(WatchHooks hooks) arm,
  Duration trailing = const Duration(milliseconds: 150),
  Duration maxWait = const Duration(seconds: 1),
  Duration minInterval = const Duration(seconds: 1),
  Duration pollInterval = const Duration(seconds: 5),
  Duration recoveryInterval = const Duration(minutes: 3),
  void Function()? onPollingRecoveryAttempt,
  int maxRestarts = 3,

  /// Records mode transitions for diagnosis (MADR 0026). Purely
  /// observational: every transition reported here already happened, and
  /// reporting one must never change which happen or when.
  WatchTransitionSink? onTransition,

  /// Fires when the transport releases a watcher slot.
  ///
  /// A watcher that degraded because the ceiling was full is waiting on a
  /// *local* condition that this signal resolves, so it re-arms at once rather
  /// than waiting out [recoveryInterval] — up to three minutes of polling at
  /// 48 host processes per minute, and forever if the slots stay occupied
  /// (0028 H2). Refusals for any other reason ignore it: a freed slot says
  /// nothing about a host that has no watcher tool.
  Stream<void>? slotReleased,
}) {
  late final StreamController<RepoWatchEvent> controller;
  Future<void> Function()? armedTeardown;
  Timer? pollTimer;
  Timer? restartTimer;
  Timer? recoveryTimer;
  Coalescer? coalescer;
  var mode = WatchMode.stopped;

  /// Why the last degradation happened, so the slot signal can be ignored
  /// unless it is the condition that actually blocked this watcher.
  WatchUnavailableReason? degradedReason;
  StreamSubscription<void>? slotSub;
  var cancelled = false;
  var restarts = 0;
  late Future<void> Function() start;
  late Future<void> Function() startOnce;
  late void Function() scheduleRestart;
  // Serialises arming — see [start] below. `startChain` is the tail of the
  // queue; `queued` is how many calls are waiting behind the running one.
  var startChain = Future<void>.value();
  var queued = 0;

  // The paths seen since the last fire, drained into the tick the coalescer
  // eventually emits — see [RepoWatchEvent.paths] for why a tick that names
  // what moved is worth this much more than one that doesn't. A poll/restart
  // tick fires with this empty, which is exactly the documented "unknown
  // scope".
  final pending = <String>{};
  const maxPaths = 512;
  var overflowed = false;

  void emit() {
    if (controller.isClosed) return;
    final paths = overflowed ? const <String>{} : Set<String>.from(pending);
    pending.clear();
    overflowed = false;
    controller.add(
      RepoWatchEvent(at: DateTime.now(), mode: mode, paths: paths),
    );
  }

  void startPolling(String cause) {
    onTransition?.call(WatchTransition.degradedToPolling, cause, restarts);
    mode = WatchMode.polling;
    pollTimer?.cancel();
    emit();
    pollTimer = Timer.periodic(pollInterval, (_) => emit());
    // A watcher that degrades to polling must not stay degraded for the rest
    // of the session — periodically retry event-driven watching so a
    // recovered network / newly-installed tool / settled volume is picked
    // back up.
    recoveryTimer?.cancel();
    recoveryTimer = Timer.periodic(recoveryInterval, (_) {
      if (cancelled) return;
      restarts = 0;
      onTransition?.call(WatchTransition.recoveryAttempted, 'poll recovery', 0);
      onPollingRecoveryAttempt?.call();
      start().catchError((_) => scheduleRestart());
    });
  }

  Future<void> teardownWatcher() async {
    // Tear the source down *before* dropping `coalescer`: an event delivered
    // in the window between nulling it and cancelling the source would
    // otherwise reach a null coalescer inside the stream callback.
    final teardown = armedTeardown;
    armedTeardown = null;
    if (teardown != null) await teardown();
    coalescer?.cancel();
    coalescer = null;
  }

  scheduleRestart = () {
    if (cancelled || controller.isClosed) return;
    if (restarts >= maxRestarts) {
      startPolling('restart budget spent ($restarts/$maxRestarts)');
      return;
    }
    onTransition?.call(
      WatchTransition.restartScheduled,
      'source died',
      restarts,
    );
    mode = WatchMode.stopped;
    // Emit immediately — without this, subscribers keep seeing whatever mode
    // was last emitted (usually `eventDriven`) for the entire restart backoff
    // window, so the UI's "watching" dot stayed lit green through a real
    // outage instead of going grey with the "Watcher stopped" affordance it
    // already has for exactly this state.
    emit();
    restarts++;
    restartTimer?.cancel();
    restartTimer = Timer(Duration(seconds: restarts * 2), () {
      if (cancelled || controller.isClosed) return;
      start().catchError((_) => scheduleRestart());
    });
  };

  final hooks = WatchHooks(
    signalPath: (path) {
      if (pending.length >= maxPaths) {
        overflowed = true;
        pending.clear();
      }
      if (!overflowed) pending.add(path);
      coalescer?.signal();
    },
    noteActivity: () {
      if (mode == WatchMode.polling) {
        onTransition?.call(
          WatchTransition.recovered,
          'event received',
          restarts,
        );
      }
      restarts = 0;
      mode = WatchMode.eventDriven;
    },
    scheduleRestart: () => scheduleRestart(),
    rearm: () {
      if (cancelled || controller.isClosed) return;
      onTransition?.call(
        WatchTransition.rearmed,
        'watched paths changed',
        restarts,
      );
      // Straight back through start(), which tears the old source down first.
      // No mode change, no backoff, no budget spend — see [WatchHooks.rearm].
      start().catchError((_) => scheduleRestart());
    },
    isCancelled: () => cancelled,
  );

  // ONE arm at a time. `startOnce` nulls `armedTeardown` before `await
  // arm(...)` and only re-assigns it afterwards, so two overlapping entries
  // each armed a source and the later assignment overwrote the earlier
  // teardown — leaving a live watcher with nothing holding it and, in
  // RemoteWatchService, leaking the slot it had reserved. That is MADR 0026 H1,
  // and it is what put a repo into the 5-second poll while its `inotifywait`
  // processes were still running on the host.
  //
  // Serialised rather than dropped: a re-arm requested during an arm is a
  // legitimate request (the watched path set changed) and must still happen —
  // just after the one in flight, so the teardown it depends on has run. At
  // most one is queued, because three timers firing during one slow arm should
  // produce one re-arm, not three.
  start = () {
    if (queued >= 1) return startChain;
    queued++;
    final next = startChain.then((_) {
      queued--;
      return startOnce();
    });
    // Keep the chain alive past a failed arm; the caller still sees the error
    // through `next`, and `scheduleRestart` is what reacts to it.
    startChain = next.then((_) {}, onError: (Object _) {});
    return next;
  };

  startOnce = () async {
    // An active attempt is underway — pause the polling-recovery retries
    // until it's clear whether this one succeeds. And stop any polling loop:
    // without this, a successful recovery from polling mode left the periodic
    // poll timer running forever alongside the event-driven watcher — a
    // status-refresh round trip every pollInterval for the rest of the
    // session, mislabeled as an event tick. If this attempt fails,
    // scheduleRestart → startPolling re-arms it.
    recoveryTimer?.cancel();
    recoveryTimer = null;
    pollTimer?.cancel();
    pollTimer = null;
    await teardownWatcher();
    if (cancelled) return;

    mode = WatchMode.eventDriven;
    coalescer = Coalescer(
      trailing: trailing,
      maxWait: maxWait,
      minInterval: minInterval,
      onFire: emit,
    );

    switch (await arm(hooks)) {
      case WatchArmed(teardown: final teardown):
        if (cancelled) {
          await teardown();
          return;
        }
        armedTeardown = teardown;
        degradedReason = null;
        onTransition?.call(WatchTransition.armed, 'arm succeeded', restarts);
        // The watcher is now armed. Announce it with one eventDriven tick so
        // the status dot turns green immediately (and pulls a fresh status)
        // instead of sitting grey — indistinguishable from "stopped" — until
        // the first file change happens to arrive. This does NOT reset the
        // restart budget: only a real event counts as proof of health, so a
        // watcher that arms then dies repeatedly still degrades to polling.
        emit();
      case WatchUnavailable(reason: final reason):
        degradedReason = reason;
        startPolling('arm unavailable: ${reason.name}');
      case WatchAborted():
        onTransition?.call(WatchTransition.stopped, 'arm aborted', restarts);
        return;
    }
  };

  Future<void> stop() async {
    onTransition?.call(WatchTransition.stopped, 'stream cancelled', restarts);
    cancelled = true;
    await slotSub?.cancel();
    slotSub = null;
    restartTimer?.cancel();
    pollTimer?.cancel();
    recoveryTimer?.cancel();
    await teardownWatcher();
    if (!controller.isClosed) await controller.close();
  }

  controller = StreamController<RepoWatchEvent>(
    onListen: () {
      // Requests an arm through the SAME serialised `start()` every other
      // trigger uses. A second arming path is exactly the shape that produced
      // 0026 H1, where two overlapping arms each armed a source and only one
      // teardown survived.
      slotSub = slotReleased?.listen((_) {
        if (cancelled || controller.isClosed) return;
        if (mode != WatchMode.polling) return;
        if (degradedReason != WatchUnavailableReason.ceiling) return;
        restarts = 0;
        onTransition?.call(
          WatchTransition.recoveryAttempted,
          'watcher slot released',
          0,
        );
        start().catchError((Object _) => scheduleRestart());
      });
      start().catchError((Object _) => scheduleRestart());
    },
    onCancel: stop,
  );
  return controller.stream;
}
