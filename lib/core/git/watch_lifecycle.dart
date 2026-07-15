import 'dart:async';

import 'coalescer.dart';
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

/// No watch source is available (no fswatch/inotifywait on the host) —
/// degrade to polling, with periodic recovery retries.
class WatchUnavailable extends WatchArm {
  const WatchUnavailable();
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
}) {
  late final StreamController<RepoWatchEvent> controller;
  Future<void> Function()? armedTeardown;
  Timer? pollTimer;
  Timer? restartTimer;
  Timer? recoveryTimer;
  Coalescer? coalescer;
  var mode = WatchMode.stopped;
  var cancelled = false;
  var restarts = 0;
  late Future<void> Function() start;
  late void Function() scheduleRestart;

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

  void startPolling() {
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
      startPolling();
      return;
    }
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
      restarts = 0;
      mode = WatchMode.eventDriven;
    },
    scheduleRestart: () => scheduleRestart(),
    isCancelled: () => cancelled,
  );

  start = () async {
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
        // The watcher is now armed. Announce it with one eventDriven tick so
        // the status dot turns green immediately (and pulls a fresh status)
        // instead of sitting grey — indistinguishable from "stopped" — until
        // the first file change happens to arrive. This does NOT reset the
        // restart budget: only a real event counts as proof of health, so a
        // watcher that arms then dies repeatedly still degrades to polling.
        emit();
      case WatchUnavailable():
        startPolling();
      case WatchAborted():
        return;
    }
  };

  Future<void> stop() async {
    cancelled = true;
    restartTimer?.cancel();
    pollTimer?.cancel();
    recoveryTimer?.cancel();
    await teardownWatcher();
    if (!controller.isClosed) await controller.close();
  }

  controller = StreamController<RepoWatchEvent>(
    onListen: () {
      start().catchError((Object _) => scheduleRestart());
    },
    onCancel: stop,
  );
  return controller.stream;
}
