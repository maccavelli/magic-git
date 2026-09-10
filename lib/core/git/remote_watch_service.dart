import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show visibleForTesting;
import '../ssh/shell_escaper.dart';
import '../ssh/ssh_command_executor.dart';
import 'bounded_watch.dart';
import 'watch_diagnostics.dart';
import 'watch_event.dart';
import 'watch_lifecycle.dart';
import 'watch_path_filter.dart';

enum RemoteWatcherTool { fswatch, inotifywait, none }

/// Suppress lock-file churn during git operations.
///
/// **ONE flag, and that is not a simplification.** `inotifywait` takes only the
/// LAST `--exclude` it is given and says so on stderr — verified on the host,
/// where `--exclude '/a/' --exclude '/b/'` delivered events from `a/` and
/// suppressed only `b/`. This was four flags, so three of them — objects,
/// reflogs and lock files, the three that matter — had never been in force on
/// the inotify arm, and the tool had been reporting that on the very channel
/// this app reads (MADR 0041 F8).
///
/// Lock files stay a `--exclude` because they live in `.git/` itself, which
/// must remain watched. The directories move to [_inotifyUnwatchedPaths], which
/// is a stronger mechanism — see there.
///
/// Shared by both sides of the `stdbuf` / bare `inotifywait` fork.
const _inotifyExcludeFlags = r"--exclude '\.lock$' ";

/// Git-internal subtrees the recursive arm must not watch AT ALL.
///
/// `--exclude` filters events the kernel has already delivered; `@<path>`
/// stops the watch being established. Measured on the host: the largest
/// repository holds 701 directories and its `inotifywait` held exactly 701
/// watch descriptors, 259 of them under `.git/objects` and 5 under `.git/logs`
/// — about 38 % of the total spent on subtrees whose every event is discarded
/// on arrival (MADR 0041 F9).
///
/// **The `./` prefix is required and is not cosmetic.** inotifywait matches the
/// path string it builds while walking, which is `./`-prefixed when the watch
/// root is `.`. Verified on the host: `@./.git/objects` took a nine-directory
/// tree from 9 watches to 5; `@.git/objects` and an absolute path both left it
/// at 9, silently.
///
/// Placed AFTER the watch root on the command line, which is the form that was
/// verified.
const _inotifyUnwatchedPaths =
    ' @./.git/objects @./.git/logs @./.git/fsmonitor--daemon';

/// Argv for the remote watcher process. Extracted so tests can assert
/// inotifywait excludes without arming an SSH stream.
List<String> remoteWatcherArgs(
  RemoteWatcherTool tool,
  BoundedWatchSpec? bounded, {
  String? pidFile,
  String? heartbeat,
  WatchLock? lock,
}) {
  // Scoped work-tree repo: watch the explicit, non-recursive bounded surface
  // (git-dir points + tracked-file dirs) instead of the whole work tree.
  if (bounded != null) {
    switch (tool) {
      case RemoteWatcherTool.fswatch:
        // Through `sh -c` like the inotify twin: fswatch needs the same
        // existence filter (see boundedFswatchScript).
        return [
          'sh',
          '-c',
          boundedFswatchScript(
            bounded.watchDirs,
            pidFile: pidFile,
            heartbeat: heartbeat,
            lock: lock,
          ),
        ];
      case RemoteWatcherTool.inotifywait:
        return [
          'sh',
          '-c',
          boundedInotifyScript(
            bounded.watchDirs,
            pidFile: pidFile,
            heartbeat: heartbeat,
            lock: lock,
          ),
        ];
      case RemoteWatcherTool.none:
        return const [];
    }
  }
  if (heartbeat != null && tool != RemoteWatcherTool.none) {
    // Leased recursive arm — see [recursiveWatchScript].
    return [
      'sh',
      '-c',
      recursiveWatchScript(
        inotify: tool == RemoteWatcherTool.inotifywait,
        excludes: _inotifyExcludeFlags,
        unwatched: _inotifyUnwatchedPaths,
        pidFile: pidFile,
        heartbeat: heartbeat,
        lock: lock,
      ),
    ];
  }
  switch (tool) {
    case RemoteWatcherTool.fswatch:
      return [
        'fswatch',
        '-0',
        '--latency',
        '0.5',
        '--exclude',
        r'\.git/.*\.lock$',
        '--exclude',
        r'\.git/objects/',
        '--exclude',
        r'\.git/logs/',
        '--exclude',
        r'\.git/fsmonitor--daemon/',
        '.',
      ];
    case RemoteWatcherTool.inotifywait:
      // inotifywait writes events with stdio, which **block-buffers** when
      // stdout is a pipe (our SSH channel has no TTY). A single change (~a few
      // bytes) would then sit unflushed in the ~4KB buffer and never reach the
      // app, so the live watcher looks dead. `stdbuf -oL` forces line-buffered
      // output so each event flushes immediately; fall back to bare
      // inotifywait if stdbuf is unavailable. (fswatch flushes per batch on
      // its own, so it needs no such wrapper.)
      return [
        'sh',
        '-c',
        'if command -v stdbuf >/dev/null 2>&1; then '
            'exec stdbuf -oL inotifywait -m -r '
            '-e modify,create,delete,move $_inotifyExcludeFlags'
            '--format %w%f .$_inotifyUnwatchedPaths; '
            'else exec inotifywait -m -r '
            '-e modify,create,delete,move $_inotifyExcludeFlags'
            '--format %w%f .$_inotifyUnwatchedPaths; fi',
      ];
    case RemoteWatcherTool.none:
      return const [];
  }
}

/// Lines `inotifywait` prints on every arm, which say nothing about this one.
///
/// The budget is [RemoteWatchService.maxDiagnosticLines] lines per arm, and
/// these two spent two of them every time — and did it right where a real
/// message lands. `--exclude: only the last option will be taken into
/// consideration` was arriving on this channel for months, next to
/// `Setting up watches`, and nobody read it (MADR 0041 F8). The one message
/// that matters most, `upper limit on inotify watches reached`, arrives the
/// same way.
///
/// Matched by prefix rather than by pattern: an exact, enumerated list of noise
/// cannot accidentally swallow a message nobody has seen yet.
bool _isWatcherStartupNoise(String line) =>
    line.startsWith('Setting up watches') ||
    line.startsWith('Watches established');

/// One repository path's watcher, and every subscriber attached to it.
///
/// The refcount is not hand-rolled: a broadcast [StreamController] already
/// calls `onListen` when its FIRST listener arrives and `onCancel` when its
/// LAST one leaves, which is exactly "build on first subscriber, tear down on
/// last". Counting by hand would mean getting the same thing right a second
/// time, in a class whose whole purpose is that one watcher exists.
///
/// See [RemoteWatchService.watch] for why one watcher per path is a
/// correctness requirement rather than a saving (MADR 0043).
class _SharedWatch {
  /// Builds a fresh watcher for this path. Replaced by every
  /// [RemoteWatchService.watch] call so the next build uses the latest
  /// caller's parameters — a rebuilt provider hands over a new `bounded`
  /// closure over new dependencies, and building the next watcher from the
  /// first caller's stale one would watch the wrong surface.
  late Stream<RepoWatchEvent> Function() build;

  /// Cancelled by [_detach] when the last subscriber leaves; the analyzer
  /// cannot see a cancel that happens in a sibling method.
  // ignore: cancel_subscriptions
  StreamSubscription<RepoWatchEvent>? _source;

  /// The most recent event, replayed to a subscriber that arrives after it.
  ///
  /// `watchLifecycle` emits once on arm and then only on real events or poll
  /// ticks, so without this a subscriber attaching to an already-armed,
  /// quiet repository would sit with no mode at all until something happened.
  RepoWatchEvent? _last;

  late final StreamController<RepoWatchEvent> _out =
      StreamController<RepoWatchEvent>.broadcast(
        onListen: _attach,
        onCancel: _detach,
      );

  /// Builds the watcher. Called by [_out] when the first subscriber arrives —
  /// never at construction, so a stream handed out by [RemoteWatchService.watch]
  /// and never listened to arms nothing.
  /// A teardown still settling, if the last subscriber left recently.
  ///
  /// Retained so the NEXT subscriber can wait for it. The host releases its
  /// lock in well under a second (MADR 0043 F4), and an arm that reaches the
  /// host inside that window is refused by its own predecessor — the whole
  /// subject of MADR 0043.
  Future<void>? _teardown;

  void _attach() {
    final pending = _teardown;
    if (pending == null) {
      _build();
      return;
    }
    // Wait for the previous watcher to give its lock back before claiming it.
    // Bounded: on expiry, arm anyway and take today's race rather than leave
    // the repository permanently unwatchable.
    unawaited(
      pending
          .timeout(RemoteWatchService.sharedTeardownGrace, onTimeout: () {})
          .whenComplete(() {
            // Everyone may have left again while we waited; if so there is
            // nothing to build for, and _attach will run again if they return.
            if (_out.hasListener) _build();
          }),
    );
  }

  void _build() {
    final Stream<RepoWatchEvent> source;
    try {
      source = build();
    } catch (e, st) {
      // A throw here would escape through the controller's onListen and
      // surface somewhere unrelated. Report it to the subscriber instead.
      if (!_out.isClosed) _out.addError(e, st);
      return;
    }
    _source = source.listen(
      (event) {
        _last = event;
        if (!_out.isClosed) _out.add(event);
      },
      onError: (Object e, StackTrace st) {
        if (!_out.isClosed) _out.addError(e, st);
      },
      // The underlying lifecycle closed its controller, which it does from
      // `stop()` — i.e. because we cancelled. Drop the handle; do NOT close
      // [_out], which outlives any one watcher and may get new subscribers.
      onDone: () => _source = null,
    );
  }

  /// Tears the watcher down. Called by [_out] when the last subscriber leaves.
  void _detach() {
    final source = _source;
    _source = null;
    // A stale event must never be replayed to the next subscriber as though it
    // described a live watcher: by the time anyone attaches again, this
    // watcher is gone and its mode is meaningless.
    _last = null;
    if (source == null) {
      _teardown = null;
      return;
    }
    // Cancelling reaches `watchLifecycle.stop()`, whose teardown now awaits the
    // host giving back the lock — so this future settling is the signal the
    // next arm needs.
    final teardown = source.cancel();
    _teardown = teardown;
    unawaited(
      teardown.whenComplete(() {
        // Only clear it if no LATER teardown has replaced it in the meantime.
        if (identical(_teardown, teardown)) _teardown = null;
      }),
    );
  }

  /// A stream for one subscriber: the retained event first, then the live feed.
  ///
  /// `Stream.multi` gives every subscriber its own controller, so each one's
  /// cancellation is independent and only the last of them reaches [_detach].
  Stream<RepoWatchEvent> subscribe() =>
      Stream<RepoWatchEvent>.multi((controller) {
        // Subscribe BEFORE replaying, so an event arriving in between is
        // delivered rather than dropped in favour of the older retained one.
        final sub = _out.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
        final last = _last;
        if (last != null) controller.add(last);
      });
}

/// Watches a remote repository for filesystem changes and emits a coalesced
/// [RepoWatchEvent] per settled burst, carrying the active [WatchMode] so the UI
/// can distinguish live events from polling fallback.
///
/// The watcher runs ON the remote host (local kernel watchers and SSHFS cannot
/// observe remotely-originated changes), streaming its event records back over
/// a dedicated SSH channel. If neither fswatch nor inotifywait is available, it
/// falls back to periodic polling so the UI still refreshes.
///
/// The restart/polling/recovery lifecycle lives in [watchLifecycle], shared
/// with `LocalWatchService`; this class owns only the remote-specific arming:
/// tool detection, the SSH stream, and delimiter parsing.
class RemoteWatchService {
  final CommandExecutor _executor;

  RemoteWatchService(
    this._executor, {
    this.onDiagnostic,
    String Function()? hostKey,
    int Function()? streamBudget,
  }) : _hostKey = hostKey ?? _noHost,
       _streamBudget = streamBudget ?? _defaultStreamBudget;

  /// Where a watcher's own stderr goes.
  final void Function(String line)? onDiagnostic;

  /// Which host this service's commands reach — the budget's owner.
  ///
  /// A callback, not a value, because the connection can change under a
  /// long-lived service instance and reading it eagerly would either pin a
  /// stale host or (if watched) rebuild the service and restart every live
  /// watcher. Resolved once per arm, and the resolved value is what both
  /// reserves and releases the slot.
  final String Function() _hostKey;

  static String _noHost() => '';

  /// The transport's live ceiling on concurrent long-lived stream channels —
  /// `SSHCommandExecutor.maxConcurrentStreams`.
  ///
  /// A callback for the same reason [_hostKey] is one: the answer changes when
  /// the dedicated stream client degrades onto the command client or is
  /// re-dialled, and reading it eagerly would either pin a stale number or, if
  /// watched, rebuild the service and restart every live watcher.
  final int Function() _streamBudget;

  /// Assumed budget when none is supplied — the degraded single-client figure,
  /// so a caller that forgets to wire it is conservative rather than optimistic.
  static int _defaultStreamBudget() => 2;

  /// Diagnostic lines reported per arm.
  static const int maxDiagnosticLines = 20;

  /// Channels reserved for the other two long-lived stream consumers: the CI
  /// job trace (`glab_service.dart`) and clone progress (`clone_controller`).
  /// Watchers must not be able to starve either.
  static const int reservedStreams = 2;

  /// Live watchers one **host** may hold at once.
  ///
  /// **Derived, not chosen.** A watcher holds exactly one long-lived SSH
  /// channel, and the executor already caps those at
  /// `SSHCommandExecutor.maxConcurrentStreams` — 8 with a dedicated stream
  /// client, 2 degraded — refusing past it with `SSHStreamBudgetExhausted`,
  /// which the arm below already handles. This is that budget minus
  /// [reservedStreams], floored at 1 so a degraded single-client session still
  /// watches the repository the user is looking at.
  ///
  /// It used to be the constant 2, and nothing connected it to the 8 it stood
  /// in front of. On a fifteen-repository host that cap forced thirteen
  /// repositories onto a poll measured at ~48 git processes per minute each,
  /// while the host used 0.17 % of its inotify watch budget (MADR 0040 F3, F5,
  /// F6; MADR 0041 F7).
  ///
  /// **Keyed by HOST, and that word is load-bearing.** MADR 0040's phase 2
  /// keyed it per (session, host) — right for the resource it derives from,
  /// since channels belong to a connection, and wrong for the resource watchers
  /// also consume. With up to eight tab containers that took the host-wide
  /// bound from 2 to as much as 48 and left nothing bounding the host at all,
  /// handing that job to a lease whose reclaim latency was six minutes. It was
  /// reverted for exactly that (MADR 0041 F5). The lease now reclaims in under
  /// a second (F11) and the host enforces one watcher per repository (F12), but
  /// the host-wide key stays: being conservative here costs a repository a
  /// watcher, and being wrong the other way costs the host.
  ///
  /// `watch_ceiling_per_host_test.dart` and `watch_ceiling_derived_test.dart`
  /// are the checks that can fail on it.
  int get maxConcurrentWatchers {
    final derived = _streamBudget() - reservedStreams;
    return derived < 1 ? 1 : derived;
  }

  /// How long a new arm waits for a previous watcher of the same repository to
  /// finish giving back its host lock, before proceeding anyway.
  ///
  /// Three minutes, matching `recoveryInterval` — the cadence a degraded
  /// repository already waits on, so this gate can never make one wait longer
  /// than the system's existing worst case.
  ///
  /// **It should never be reached.** The teardown it waits on is bounded by its
  /// own 15-second command timeout (`releaseHostClaims`), so a realistic
  /// teardown settles in seconds. This is the backstop for a future that never
  /// completes at all, and the cost of reaching it is a repository with no
  /// watcher AND no polling for the duration — the lifecycle has not been built
  /// yet, so nothing emits. That is why the two bounds are coupled, and why
  /// removing the inner one turns this into a three-minute stall (MADR 0043).
  ///
  /// Proceeding anyway on expiry is deliberate: it yields today's behaviour — a
  /// possible race with a dying watcher — and never a repository that cannot be
  /// watched again because one teardown wedged.
  static const Duration sharedTeardownGrace = Duration(minutes: 3);

  /// How often the client refreshes a watcher's heartbeat while it is alive.
  static const Duration heartbeatInterval = Duration(seconds: 60);

  /// A heartbeat older than this means the client that armed the watcher is
  /// gone. Generously above [heartbeatInterval] so a slow link or a busy
  /// exclusive lane cannot orphan a live watcher.
  static const Duration leaseStaleAfter = Duration(minutes: 5);

  /// Registry paths for [repoPath], in the git-dir so they travel with the
  /// repository and never sit at a guessable /tmp path (0025 M4's lesson).
  /// Registry file for ONE watcher instance.
  ///
  /// Tokenised per instance, not per repo. A single `mg-watch.pid` per repo was
  /// truncated by every re-arm, so the registry named only the newest watcher
  /// and the connect sweep had no record of any orphan to reclaim (0027).
  static String watchPidFile(String gitDir, String token) =>
      '$gitDir/mg-watch.$token.pid';

  /// Lease file for ONE watcher instance.
  ///
  /// Tokenised for a sharper reason than the pid file: a single `mg-watch.hb`
  /// per repo is refreshed by whichever watcher is currently healthy, so an
  /// orphan testing it sees a fresh lease and never exits — self-termination
  /// was disabled exactly while orphans accumulate (0027).
  static String watchHeartbeatFile(String gitDir, String token) =>
      '$gitDir/mg-watch.$token.hb';

  static int _tokenSeq = 0;

  /// A token unique among *live* watchers. Time plus a sequence: it must not
  /// collide with another instance, and needs no other property.
  static String newWatchToken() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${(_tokenSeq++).toRadixString(36)}';

  /// Reclaims watcher processes whose client is gone.
  ///
  /// Run at connect: a heartbeat left by a previous session is by definition
  /// stale, so anything still running from it is an orphan. This is the
  /// "reconnect-time sweep" 0022 M5 named and never built — the absence of
  /// which left 19 `inotifywait` processes on the host, the oldest 16.9 days.
  ///
  /// Best-effort: a failure here must never affect the connect.
  Future<void> sweepStaleWatchers(Map<String, String> repoToGitDir) async {
    if (repoToGitDir.isEmpty) return;
    for (final entry in repoToGitDir.entries) {
      try {
        await _executor.execute(
          repoPath: entry.key,
          gitArgs: [
            'sh',
            '-c',
            watcherSweepScript([entry.value], staleAfter: leaseStaleAfter),
          ],
          lane: ExecLane.isolated,
          timeout: const Duration(seconds: 20),
        );
      } catch (e) {
        onDiagnostic?.call('watcher sweep failed for ${entry.key}: $e');
      }
    }
  }

  /// Live watcher processes per host. Static because the ceiling is a property
  /// of the *host* budget, not of any one service instance — several providers
  /// construct their own service against the same host, and counting per
  /// instance would hand each its own budget and multiply the ceiling (0028
  /// amendment 0028.1). Keyed by host because the process now holds several
  /// sessions at once (MADR 0039 F4).
  static final Map<String, int> _liveByHost = {};

  /// Broadcasts the host whose watcher slot was just released, so a repo that
  /// was refused by the ceiling can take it immediately instead of polling
  /// until its recovery timer fires (0028 H2). Broadcast and never closed: it
  /// is a process-wide signal with the same lifetime as the counter it reports
  /// on. It carries the host so a release on one host does not wake — and
  /// pointlessly re-arm — a repo waiting on another.
  static final StreamController<String> _slotReleases =
      StreamController<String>.broadcast();

  /// Fires once per released watcher slot, carrying that slot's host.
  static Stream<String> get slotReleases => _slotReleases.stream;

  /// Releases on [host] alone, in the shape `watchLifecycle` takes.
  static Stream<void> slotReleasesForHost(String host) =>
      _slotReleases.stream.where((h) => h == host).map((_) {});

  /// Live watcher count across every host — for tests and diagnostics.
  static int get liveWatchers =>
      _liveByHost.values.fold(0, (sum, n) => sum + n);

  /// Live watcher count for one host — for tests and diagnostics.
  static int liveWatchersFor(String host) => _liveByHost[host] ?? 0;

  /// Test seam: the counter is process-global, so a test that arms watchers
  /// must be able to start from a known state.
  @visibleForTesting
  static void resetWatcherCount() => _liveByHost.clear();

  /// Files one transition against [repoPath], stamping it with the live watcher
  /// count — the field that separates a leaked **slot** (H1: refusals persist
  /// with no watcher process alive) from a leaked **process** (H3). MADR 0026.
  static void _record(
    String repoPath,
    WatchTransition kind,
    String cause,
    int restarts,
  ) => watchDiagnostics
      .forRepo(repoPath)
      .add(
        WatchTransitionRecord(
          at: DateTime.now(),
          kind: kind,
          repoPath: repoPath,
          cause: cause,
          liveWatchers: liveWatchers,
          restarts: restarts,
        ),
      );

  /// Cap on the un-delimited stdout buffer. A watcher tool that streams partial
  /// output without ever emitting the record delimiter (a wedged or misbehaving
  /// fswatch/inotifywait) would otherwise grow `buffer` without bound. Past this
  /// we drop what's accumulated and resync on the next delimiter.
  static const int _maxBufferChars = 1 << 20; // 1 MiB

  /// How long a bounded watch waits after a git-state event before recomputing
  /// its surface and re-arming. Long enough that one `git add`/commit — which
  /// writes the index, refs and lock files in quick succession — costs a single
  /// re-arm rather than one per write.
  static const Duration _rearmDebounce = Duration(seconds: 2);

  /// Watches [repoPath] for changes.
  ///
  /// **One watcher per repository path, however many callers ask for it.** The
  /// first subscriber arms; every later subscriber is attached to that same
  /// watcher and receives the same events, with the most recent one replayed
  /// immediately so a late arrival's mode indicator is right without waiting
  /// for the next tick. The watcher is torn down when the LAST subscriber
  /// leaves.
  ///
  /// This is a correctness guarantee, not an optimisation. Arming twice used to
  /// be possible and the second arm was refused by this app's own host-side
  /// lock — a healthy repository degraded to polling for three minutes because
  /// it collided with itself, and the diagnostic blamed "another live watcher"
  /// when there was no other session (MADR 0043 F1, F2). `heldByAnother` must
  /// only ever mean another SESSION, and that is true only if one session
  /// cannot arm a repository twice.
  ///
  /// Scoped to this service instance, which is one connection, which is one
  /// tab. Two tabs watching one repository still meet at the host lock, and
  /// that is correct — they are different sessions (MADR 0041 F12).
  ///
  /// [bounded], when supplied, switches to the **scoped work-tree** surface for
  /// a dotfiles-style repo (git-dir + tracked-file dirs, non-recursive) instead
  /// of a recursive watch of the whole work tree — see [BoundedWatchSpec] for
  /// why a recursive `$HOME` watch is unacceptable. Only pass it when the repo's
  /// type toggle marks it as such; an ordinary repo leaves it null and gets the
  /// unchanged recursive behaviour.
  ///
  /// The timing parameters and [bounded] belong to whichever call most recently
  /// asked for this path; they are used when the NEXT watcher for it is built.
  /// A watcher already running keeps what it was built with. In production
  /// `repoWatchProvider` is the only caller and passes only [bounded], derived
  /// from the same connection state for the same path — but it passes a FRESH
  /// closure on every rebuild, which is why the latest one has to win rather
  /// than the first (MADR 0043 plan, deviation (a)).
  Stream<RepoWatchEvent> watch(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = const Duration(milliseconds: 150),
    Duration maxWait = const Duration(seconds: 1),
    Duration minInterval = const Duration(seconds: 1),
    Duration pollInterval = const Duration(seconds: 5),
    Duration recoveryInterval = const Duration(minutes: 3),
  }) {
    final shared = _shared.putIfAbsent(repoPath, _SharedWatch.new);
    shared.build = () => _createLifecycle(
      repoPath,
      bounded: bounded,
      trailing: trailing,
      maxWait: maxWait,
      minInterval: minInterval,
      pollInterval: pollInterval,
      recoveryInterval: recoveryInterval,
    );
    return shared.subscribe();
  }

  /// The watchers this service has built, one per repository path.
  ///
  /// An INSTANCE field, deliberately. A static map would share one watcher
  /// between two tabs, which are two connections with two independent
  /// executors — and would re-create exactly the process-global coupling MADR
  /// 0039 spent ten phases partitioning by session.
  ///
  /// Entries are never removed. One idle entry per path is a broadcast
  /// controller and two null fields; the alternative — retiring an entry when
  /// its last subscriber leaves — races a subscriber that has been handed a
  /// stream by [watch] and has not listened to it yet, which would build a
  /// watcher no map knows about. The service itself is rebuilt whenever the
  /// executor is, so the map's lifetime is one connection's.
  final Map<String, _SharedWatch> _shared = {};

  /// Builds one watcher for [repoPath]. Everything below is per-watcher state,
  /// which is why it lives in a factory rather than in [watch]: [watch] may be
  /// called many times for one path and must not produce a second one.
  Stream<RepoWatchEvent> _createLifecycle(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = const Duration(milliseconds: 150),
    Duration maxWait = const Duration(seconds: 1),
    Duration minInterval = const Duration(seconds: 1),
    Duration pollInterval = const Duration(seconds: 5),
    Duration recoveryInterval = const Duration(minutes: 3),
  }) {
    // Cached across restarts within this stream's lifetime — the answer can't
    // change between one blip's retries, so there's no need to re-probe the
    // remote for it every time. Cleared while recovering from polling, since
    // enough time has passed there that it's worth re-checking.
    RemoteWatcherTool? cachedTool;
    // Debounces the deliberate re-arm below. Lives outside `arm` so it spans
    // re-arms; cancelled by every teardown.
    Timer? rearmTimer;
    // Refreshes the watcher's heartbeat while this client is alive. The
    // watcher reads it and exits on its own when it goes stale, which is the
    // only thing that survives losing the channel (0025 A/C1).
    Timer? heartbeatTimer;

    return watchLifecycle(
      trailing: trailing,
      maxWait: maxWait,
      minInterval: minInterval,
      pollInterval: pollInterval,
      recoveryInterval: recoveryInterval,
      onPollingRecoveryAttempt: () => cachedTool = null,
      slotReleased: slotReleasesForHost(_hostKey()),
      onTransition: (kind, cause, restarts) {
        _record(repoPath, kind, cause, restarts);
        // Degradation is the expensive state and the one a maintainer needs
        // explained: report it on the channel watcher stderr already uses, so
        // "why is this repo polling" is answerable while it is polling
        // (MADR 0026 Phase 3) rather than only from a host-side census.
        if (kind == WatchTransition.degradedToPolling) {
          final summary = watchDiagnostics.forRepo(repoPath).degradationSummary;
          if (summary != null) onDiagnostic?.call(summary);
        }
      },
      arm: (hooks) async {
        // ONE identity per arm. Every re-arm is a new watcher instance and gets
        // its own lease and registry files, so a live instance can neither
        // overwrite its predecessor's pid record nor refresh its lease (0027).
        final token = newWatchToken();
        final tool = cachedTool ??= await _detectWatcher(repoPath);
        if (hooks.isCancelled()) return const WatchAborted();

        if (tool == RemoteWatcherTool.none) {
          _record(repoPath, WatchTransition.armFailed, 'no watcher tool', 0);
          return const WatchUnavailable(WatchUnavailableReason.noTool);
        }

        // Resolve the bounded surface HERE, on every arm, rather than closing
        // over one computed once for the stream's life. The tracked-file set
        // changes constantly on a dotfiles repo, and a frozen surface meant a
        // file staged into a directory nothing was watching yet never produced
        // an event again until the whole provider was torn down (0022 H5).
        final spec = bounded == null ? null : await bounded();
        if (hooks.isCancelled()) return const WatchAborted();

        // Refuse before arming rather than accumulating. Nothing bounded this
        // before, and the result was 19 orphaned watchers on the real host
        // (0025 C3). Degrading to polling is a worse experience for this repo
        // and a far better one than a host slowly filling with processes
        // nobody is reading.
        // Resolved ONCE per arm and reused for the release below: a
        // connection that changes host mid-arm must not credit the slot back
        // to a host that never paid for it.
        final host = _hostKey();
        final liveHere = _liveByHost[host] ?? 0;
        if (liveHere >= maxConcurrentWatchers) {
          onDiagnostic?.call(
            'watcher ceiling reached for $host '
            '($liveHere/$maxConcurrentWatchers) — polling $repoPath instead',
          );
          _record(
            repoPath,
            WatchTransition.armFailed,
            'ceiling $liveHere/$maxConcurrentWatchers',
            0,
          );
          return const WatchUnavailable(WatchUnavailableReason.ceiling);
        }
        // RESERVE the slot here, synchronously, rather than counting it once
        // the arm succeeds. Arms are concurrent — several repos arm at once on
        // connect — and every one of them awaits the tool probe before this
        // point, so a check that did not reserve let all of them pass the
        // ceiling together. Released on every path that does not end armed.
        _liveByHost[host] = liveHere + 1;
        var armCounted = true;
        void releaseSlot() {
          if (!armCounted) return;
          armCounted = false;
          final n = _liveByHost[host] ?? 0;
          if (n > 1) {
            _liveByHost[host] = n - 1;
          } else {
            _liveByHost.remove(host);
          }
          // Announce room on THIS host. Several waiting repos may wake
          // together; the reserve-then-arm ceiling settles who gets it, and the
          // losers are refused exactly as they were before.
          if (!_slotReleases.isClosed) _slotReleases.add(host);
        }

        // EVERY exit from here releases the slot. The four explicit releases
        // below stay — each pairs its release with a distinct `_record` cause
        // and `WatchUnavailable` reason, which is what makes
        // `degradationSummary` legible — but they are not the guarantee.
        //
        // `executeStream` can fail five ways and only one was caught (0024
        // M2's `SSHStreamBudgetExhausted`); the other four propagated out of
        // `arm` with the slot still reserved, and nothing ever gave it back.
        // Two of those on one host and every repository on it is refused for
        // the rest of the session, with no watcher process alive to justify it
        // — MADR 0026's H1 exactly. Structural, so that a sixth failure type
        // added later cannot reintroduce it (MADR 0040 F8).
        try {
          final gitDir = spec?.gitDir ?? '$repoPath/.git';
          final heartbeat = watchHeartbeatFile(gitDir, token);
          // One watcher per repository, decided on the HOST. The client's slot
          // counter is correct only while exactly one client exists, and this
          // app has had up to eight tab containers since `11689cc` — plus any
          // second copy of the app pointed at the same bastion (MADR 0041 F12).
          final lock = (gitDir: gitDir, token: token);
          Future<void> beat() async {
            try {
              await _executor.execute(
                repoPath: repoPath,
                gitArgs: [
                  'sh',
                  '-c',
                  'touch ${ShellEscaper.escape(heartbeat)}',
                ],
                lane: ExecLane.isolated,
                timeout: const Duration(seconds: 15),
              );
            } catch (_) {
              // Best-effort once the watcher is up. A missed beat costs nothing
              // until leaseStaleAfter — but see the AWAITED first beat below,
              // which is not optional.
            }
          }

          /// Gives back everything this arm claimed on the host: its lease,
          /// and — while it still owns it — the repository lock.
          ///
          /// Best-effort by construction. The common failure is a disconnected
          /// executor, which is also the case where the watcher has already
          /// taken stdin EOF and released these itself; nothing to report and
          /// nothing to retry.
          ///
          /// **The 15-second timeout is load-bearing and coupled to
          /// `_SharedWatch`'s teardown gate.** That gate holds the next arm for
          /// this path until this future settles, bounded at
          /// [sharedTeardownGrace]. Because this call cannot take longer than
          /// its own timeout, the gate's bound is a backstop that should never
          /// be reached. Remove this timeout and the gate becomes a
          /// three-minute stall on a repository with no watcher and no polling
          /// (MADR 0043 plan, decision 3).
          Future<void> releaseHostClaims() async {
            try {
              await _executor.execute(
                repoPath: repoPath,
                gitArgs: [
                  'sh',
                  '-c',
                  'rm -f ${ShellEscaper.escape(heartbeat)}; '
                      '${watchLockReleaseScript(lock)}',
                ],
                lane: ExecLane.isolated,
                timeout: const Duration(seconds: 15),
              );
            } catch (_) {
              // See the doc comment: swallowing is the contract, not an
              // oversight.
            }
          }

          // STAMP THE LEASE BEFORE ARMING, and wait for it.
          //
          // The watcher script's first action is `[ -f <heartbeat> ] || exit 0`.
          // This used to be fired with `unawaited(beat())` *after* the stream was
          // launched, so the script checked for a file the client had not created
          // yet and exited in ~5 ms — every arm, because the heartbeat filename
          // is tokenised per instance and can never pre-exist. Three arms died in
          // seconds, the restart budget emptied, and the repo polled forever at
          // 48 host processes a minute (0027 deviation (b)).
          //
          // It is also what a lease *means*: a live client owns this watcher, so
          // the client's mark must precede the watcher. One round trip, on a path
          // that already pays one.
          await beat();

          final CommandStreamHandle handle;
          try {
            handle = await _executor.executeStream(
              repoPath: repoPath,
              gitArgs: remoteWatcherArgs(
                tool,
                spec,
                pidFile: watchPidFile(gitDir, token),
                heartbeat: heartbeat,
                lock: lock,
              ),
            );
          } on SSHStreamBudgetExhausted catch (e) {
            releaseSlot();
            // Deterministic, not a blip: retrying just hits the same wall and
            // spends the restart budget doing it. Poll this repo instead, and
            // say why (0024 M2).
            onDiagnostic?.call('$e — falling back to polling for this repo');
            _record(repoPath, WatchTransition.armFailed, 'stream budget', 0);
            return const WatchUnavailable(WatchUnavailableReason.streamBudget);
          }
          if (hooks.isCancelled()) {
            releaseSlot();
            await handle.cancel();
            return const WatchAborted();
          }

          // A script-level refusal arrives as an exit STATUS, not an exception:
          // the arming scripts exit with a distinct code when none of their
          // paths exist yet (0022 M6) or when another live watcher already holds
          // the repository (0041 F12). Catch both here so they degrade to
          // polling-with-recovery instead of looking like a watcher that armed
          // and died — which would spend the restart budget on three doomed
          // retries first.
          //
          // EVERY arm now waits, where this used to be bounded-arms-only: the
          // lock refusal can come from the recursive script too. A live watcher
          // never completes exitCode, so the cost is one capped 250 ms wait on
          // a path that already paid for an SSH round trip.
          {
            final early = await handle.exitCode.timeout(
              const Duration(milliseconds: 250),
              onTimeout: () => null,
            );
            if (early == boundedWatchLockedExit) {
              releaseSlot();
              await handle.cancel();
              onDiagnostic?.call(
                'another live watcher already holds $repoPath — polling here',
              );
              _record(
                repoPath,
                WatchTransition.armFailed,
                'held by another watcher',
                0,
              );
              return const WatchUnavailable(
                WatchUnavailableReason.heldByAnother,
              );
            }
            if (spec != null && early == boundedWatchNoPathsExit) {
              releaseSlot();
              await handle.cancel();
              _record(
                repoPath,
                WatchTransition.armFailed,
                'no watched paths',
                0,
              );
              return const WatchUnavailable(
                WatchUnavailableReason.noWatchedPaths,
              );
            }
          }

          var buffer = '';
          final delimiter = tool == RemoteWatcherTool.fswatch ? '\u0000' : '\n';
          final sub = handle.stdout.listen(
            (chunk) {
              hooks.noteActivity();
              buffer += chunk;
              // Cursor, not repeated re-slicing. `buffer = buffer.substring(...)`
              // per record copies the whole remainder AND restarts the scan at 0,
              // which is quadratic in the arriving chunk — measured at 522 ms of
              // UI-isolate time for a 20k-event `git checkout` burst at
              // dartssh2's 32 KiB packet size, against ~1 ms here (0024 A1).
              // One remainder copy per chunk instead of one per record.
              var start = 0;
              var idx = buffer.indexOf(delimiter, start);
              while (idx >= 0) {
                final event = buffer.substring(start, idx);
                start = idx + 1;
                // Bounded mode watches absolute paths; remap them to the
                // repo-relative (`.git/…` for git-dir) shape the filter expects.
                // Recursive mode already emits repo-relative paths (cwd = repo).
                final path = spec == null
                    ? event
                    : relativizeBoundedEvent(event, spec);
                if (path != null && shouldTriggerWatch(path)) {
                  hooks.signalPath(path);
                  // A bounded surface is derived from the index, so a git-state
                  // change can mean "there are now tracked files in directories
                  // this arming does not cover". Recompute and re-arm, debounced
                  // — one `git add` writes the index several times (0022 H5).
                  if (spec != null && path.startsWith('.git/')) {
                    rearmTimer?.cancel();
                    rearmTimer = Timer(_rearmDebounce, () {
                      if (hooks.isCancelled()) return;
                      hooks.rearm();
                    });
                  }
                }
                idx = buffer.indexOf(delimiter, start);
              }
              if (start > 0) buffer = buffer.substring(start);
              // Whatever remains is an unterminated partial record. If it has
              // grown past a sane bound, the watcher is emitting output that
              // never completes a record — drop it and resync on the next
              // delimiter rather than buffering unbounded.
              if (buffer.length > _maxBufferChars) {
                developer.log(
                  'watcher output exceeded $_maxBufferChars chars with no '
                  'delimiter; dropping buffered partial',
                  name: 'RemoteWatchService',
                );
                buffer = '';
              }
            },
            // WHY the stream ended, filed before the engine turns it into a
            // restart. `scheduleRestart` records `restartScheduled` with the
            // cause 'source died' for both cases, so a watcher that exited on
            // its own — lease expired, stdin EOF, reclaimed by a sweep — was
            // indistinguishable from a channel that errored under it. A repo
            // re-arming 46 s after its last heartbeat therefore left no record
            // of which had happened, which is MADR 0041's open question.
            onDone: () {
              _record(repoPath, WatchTransition.stopped, 'watcher exited', 0);
              hooks.scheduleRestart();
            },
            onError: (Object e) {
              _record(
                repoPath,
                WatchTransition.stopped,
                'stream error: ${e.runtimeType}',
                0,
              );
              hooks.scheduleRestart();
            },
          );

          // Read stderr even when no one is listening to the diagnostics.
          //
          // Two reasons, and both bite. `inotifywait` reports per-directory
          // failures here — canonically "upper limit on inotify watches reached"
          // — which is the one message that says WHY a watcher died and names
          // the sysctl to raise; it used to be dropped, leaving a silent polling
          // fallback. And dartssh2's `SSHSession._stderrController` is a
          // single-subscription controller with no listener
          // (ssh_session.dart:74), so unread stderr is queued in the Dart heap
          // for the life of the channel — and the watcher's channel is the
          // longest-lived one in the app (0024 H3).
          // The lease was stamped and awaited before the arm; from here it only
          // needs refreshing.
          heartbeatTimer?.cancel();
          heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => beat());

          var diagnosticsSeen = 0;
          var errBuffer = '';
          final errSub = handle.stderr.listen((chunk) {
            errBuffer += chunk;
            var start = 0;
            var i = errBuffer.indexOf('\n', start);
            while (i >= 0) {
              final line = errBuffer.substring(start, i).trim();
              start = i + 1;
              if (line.isNotEmpty &&
                  !_isWatcherStartupNoise(line) &&
                  diagnosticsSeen < maxDiagnosticLines) {
                diagnosticsSeen++;
                developer.log(line, name: 'RemoteWatchService');
                onDiagnostic?.call(line);
              }
              i = errBuffer.indexOf('\n', start);
            }
            if (start > 0) errBuffer = errBuffer.substring(start);
            if (errBuffer.length > _maxBufferChars) errBuffer = '';
          }, onError: (Object _) {});

          return WatchArmed(() async {
            releaseSlot();
            heartbeatTimer?.cancel();
            heartbeatTimer = null;
            rearmTimer?.cancel();
            rearmTimer = null;
            // Cancel the stdout subscription *before* the handle, mirroring the
            // engine's source-before-coalescer ordering.
            await sub.cancel();
            await errSub.cancel();
            await handle.cancel();
            // RELEASE THE HOST CLAIMS. Closing the channel is the fast path — the
            // watcher's stdin reaches EOF and its trap runs within a second
            // (0041 F11) — and this is the backstop's backstop, for the case
            // where the channel died without the host noticing. Without it the
            // watcher waits out `leaseStaleAfter`; with it, the next lease poll
            // ends it.
            //
            // Ownership, which is why this removes the heartbeat and not the
            // pid file: the CLIENT wrote the heartbeat, so the client removes
            // it; the WATCHER wrote the pid file, so its own cleanup removes
            // that. Neither touches the other's, so a half-dead pair is still
            // exactly the shape `watcherSweepScript`'s two loops reclaim.
            //
            // After `handle.cancel()`, not before: the channel close is the
            // sub-second path and must not queue behind a round trip on the
            // command client. Unawaited and swallowing, because a teardown
            // during a disconnect has no executor to talk to and must not fail
            // or stall for it.
            // AWAITED, where this used to be fire-and-forget. The next arm for
            // this repository waits on this future before it opens its own
            // stream, so "the teardown finished" has to mean "the host lock is
            // gone" — otherwise the gate lets the arm through into exactly the
            // window it exists to close (MADR 0043 F3, F4).
            await releaseHostClaims();
          });
        } catch (_) {
          // Idempotent (`armCounted`), so this is safe even on the paths that
          // already released explicitly.
          releaseSlot();
          // Rethrow rather than degrade: the lifecycle engine turns a throw
          // into a scheduled restart, which is the right answer to a transport
          // blip. Converting it to `WatchUnavailable` here would spend the
          // restart budget differently — a behaviour change this does not want.
          rethrow;
        }
      },
    );
  }

  Future<RemoteWatcherTool> _detectWatcher(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'sh',
        '-c',
        'if command -v fswatch >/dev/null 2>&1; then echo fswatch; '
            'elif command -v inotifywait >/dev/null 2>&1; then echo inotifywait; '
            'else echo none; fi',
      ],
      lane: ExecLane.read,
      // Idempotent and read-only, so a blip is worth one re-issue.
      retries: 1,
    );
    // A failed command is not evidence about the host's tooling. Reading it as
    // `none` cached that verdict for the stream's life and bought three
    // minutes of five-second polling on a host with a perfectly good fswatch
    // (0024 M3). Throwing lets watchLifecycle's restart budget retry in
    // seconds — which is what it is for — and nothing is cached, because the
    // assignment at the call site never completes.
    if (!result.isSuccess) {
      throw StateError(
        'watcher probe failed (exit ${result.exitCode}): '
        '${result.stderr.trim()}',
      );
    }
    switch (result.stdout.trim()) {
      case 'fswatch':
        return RemoteWatcherTool.fswatch;
      case 'inotifywait':
        return RemoteWatcherTool.inotifywait;
      default:
        return RemoteWatcherTool.none;
    }
  }
}
