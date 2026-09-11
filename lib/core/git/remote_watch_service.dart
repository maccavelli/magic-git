import 'dart:async';

import '../ssh/ssh_command_executor.dart';
import 'bounded_watch.dart';
import 'watch/admission/host_watcher_budget.dart';
import 'watch/admission/watch_admission.dart';
import 'watch/engine/watch_engine.dart';
import 'watch/source/remote/git_dir_resolver.dart';
import 'watch/source/remote/remote_watch_source.dart';
import 'watch/source/remote/watcher_tool_probe.dart';
import 'watch/watch_timings.dart';
import 'watch_diagnostics.dart';
import 'watch_event.dart';

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

/// Watches a remote repository for filesystem changes and emits a coalesced
/// [RepoWatchEvent] per settled burst, carrying the active [WatchMode] so the UI
/// can distinguish live events from polling fallback.
///
/// The watcher runs ON the remote host (local kernel watchers and SSHFS cannot
/// observe remotely-originated changes), streaming its event records back over
/// a dedicated SSH channel. If neither fswatch nor inotifywait is available, it
/// falls back to periodic polling so the UI still refreshes.
///
/// The restart/polling/recovery sequencing lives in [WatchEngine], shared with
/// `LocalWatchService`; this class builds one per watcher over a
/// [RemoteWatchSource], which owns the remote-specific arming.
class RemoteWatchService {
  final CommandExecutor _executor;

  RemoteWatchService(
    this._executor, {
    this.onDiagnostic,
    String Function()? hostKey,
    int Function()? streamBudget,
    WatchAdmission? admission,
    required this.gitDirOf,
  }) : _hostKey = hostKey ?? _noHost,
       _streamBudget = streamBudget ?? _defaultStreamBudget,
       admission = admission ?? WatchAdmission(budget: HostWatcherBudget());

  /// Whether a watcher may arm: this session's exclusion per repository lock,
  /// then the host's budget (MADR 0045 section 3).
  ///
  /// Production passes the tab container's `watchAdmissionProvider`, whose
  /// budget every tab shares and whose exclusion outlives this service across a
  /// reconnect. A service built without one gets a private budget and
  /// exclusion — what a test that builds its own service wants, and never what
  /// a process with several tabs wants.
  final WatchAdmission admission;

  /// Where a repository's own git dir is: the directory its watcher locks and
  /// keeps its lease in, and the key the connect-time sweep reclaims by.
  ///
  /// Required, with no default (plan decision (d)). The assumption it replaces,
  /// `'$repoPath/.git'`, names a FILE in a linked worktree, so the host's lock
  /// under it failed and every linked worktree was refused as though another
  /// watcher held it (MADR 0045 F10). Production passes git's own answer;
  /// tests say explicitly that their repositories are conventional.
  final GitDirResolver gitDirOf;

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
  static const int maxDiagnosticLines = WatchTimings.defaultMaxDiagnosticLines;

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

  /// Upper bound on how long an arm waits for either signal before giving up
  /// on both and treating the watcher as armed.
  ///
  /// **This is a backstop, not a cost.** One of the two always arrives: a
  /// refusal completes `exitCode` in well under a round trip, and a healthy arm
  /// writes [watchArmedMarker] to stderr as its next act. Reaching this ceiling
  /// means a host that produced neither — the case the fixed 250 ms wait
  /// handled by accident.
  ///
  /// Generous, because nothing waits it out in practice. The 250 ms it replaces
  /// was paid by every arm that SUCCEEDED, which made it 63 % of the cost of a
  /// tab switch (MADR 0044 F7); this is paid only by an arm that has already
  /// gone wrong.
  static const Duration armSignalCeiling = WatchTimings.defaultArmSignalCeiling;

  /// How often the client refreshes a watcher's heartbeat while it is alive.
  static const Duration heartbeatInterval =
      WatchTimings.defaultHeartbeatInterval;

  /// A heartbeat older than this means the client that armed the watcher is
  /// gone. Generously above [heartbeatInterval] so a slow link or a busy
  /// exclusive lane cannot orphan a live watcher.
  static const Duration leaseStaleAfter = WatchTimings.defaultLeaseStaleAfter;

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

  /// The git dir to sweep for each of [repoPaths]: its [scopedGitDirs] entry
  /// when it is scoped, otherwise [gitDirOf]'s answer — the directory its
  /// watcher locks, so a linked worktree's orphans are looked for where they
  /// are (MADR 0045 F10).
  ///
  /// Resolved one at a time. A repository that cannot be resolved is left out
  /// and reported: the sweep is housekeeping, and one unreachable path must not
  /// cost the others theirs.
  Future<Map<String, String>> resolveSweepTargets(
    Iterable<String> repoPaths,
    Map<String, String> scopedGitDirs,
  ) async {
    final targets = <String, String>{};
    for (final repoPath in repoPaths) {
      final scoped = scopedGitDirs[repoPath];
      if (scoped != null) {
        targets[repoPath] = scoped;
        continue;
      }
      try {
        targets[repoPath] = await gitDirOf(repoPath);
      } catch (e) {
        onDiagnostic?.call(
          'watcher sweep skipped $repoPath: its git dir did not resolve: $e',
        );
      }
    }
    return targets;
  }

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
          timeout: WatchTimings.defaultSweepTimeout,
        );
      } catch (e) {
        onDiagnostic?.call('watcher sweep failed for ${entry.key}: $e');
      }
    }
  }

  /// Files one transition against [repoPath], stamping it with the live watcher
  /// count — the field that separates a leaked **slot** (H1: refusals persist
  /// with no watcher process alive) from a leaked **process** (H3). MADR 0026.
  void _record(
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
          liveWatchers: admission.budget.liveTotal,
          restarts: restarts,
        ),
      );

  /// Watches [repoPath] for changes.
  ///
  /// **Every call builds its own watcher.** Sharing one watcher between callers
  /// is Riverpod's job: `repoWatchProvider` is the only production caller, and a
  /// provider already has one instance per repository per container. Doing it
  /// here as well is what let a leave, an arrive and a leave inside one
  /// teardown orphan a watcher (MADR 0043.1), and what let a rebuild keep the
  /// first caller's parameters (MADR 0045 F1, F2).
  ///
  /// **One LIVE watcher per repository per session is still guaranteed** — by
  /// [admission], not by sharing. A watcher arms only once this session's
  /// previous watcher of the same repository has given its host lock back: an
  /// arm reaching the host inside that window is refused by its own
  /// predecessor, and `heldByAnother` must only ever mean another session
  /// (MADR 0043 F1, F2).
  ///
  /// Two tabs watching one repository are two sessions with two exclusions, and
  /// still meet at the host lock — which is correct (MADR 0041 F12).
  ///
  /// [bounded], when supplied, switches to the **scoped work-tree** surface for
  /// a dotfiles-style repo (git-dir + tracked-file dirs, non-recursive) instead
  /// of a recursive watch of the whole work tree — see [BoundedWatchSpec] for
  /// why a recursive `$HOME` watch is unacceptable. Only pass it when the repo's
  /// type toggle marks it as such; an ordinary repo leaves it null and gets the
  /// unchanged recursive behaviour.
  Stream<RepoWatchEvent> watch(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = WatchTimings.defaultTrailing,
    Duration maxWait = WatchTimings.defaultMaxWait,
    Duration minInterval = WatchTimings.defaultMinInterval,
    Duration pollInterval = WatchTimings.defaultPollInterval,
    Duration recoveryInterval = WatchTimings.defaultRecoveryInterval,
  }) {
    return _createLifecycle(
      repoPath,
      bounded: bounded,
      trailing: trailing,
      maxWait: maxWait,
      minInterval: minInterval,
      pollInterval: pollInterval,
      recoveryInterval: recoveryInterval,
    );
  }

  /// Builds one watcher for [repoPath]. Everything below is that watcher's own
  /// state; the next call builds the next watcher.
  Stream<RepoWatchEvent> _createLifecycle(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = WatchTimings.defaultTrailing,
    Duration maxWait = WatchTimings.defaultMaxWait,
    Duration minInterval = WatchTimings.defaultMinInterval,
    Duration pollInterval = WatchTimings.defaultPollInterval,
    Duration recoveryInterval = WatchTimings.defaultRecoveryInterval,
  }) {
    final source = RemoteWatchSource(
      executor: _executor,
      probe: WatcherToolProbe(_executor),
      gitDirOf: gitDirOf,
      admission: admission,
      hostKey: _hostKey,
      capacity: () => maxConcurrentWatchers,
      timings: WatchTimings.standard,
      record: (kind, cause) => _record(repoPath, kind, cause, 0),
      onDiagnostic: onDiagnostic,
    );

    return WatchEngine(
      source: source,
      repoPath: repoPath,
      bounded: bounded,
      timings: WatchTimings(
        trailing: trailing,
        maxWait: maxWait,
        minInterval: minInterval,
        pollInterval: pollInterval,
        recoveryInterval: recoveryInterval,
      ),
      // Enough time has passed while polling that the host is worth asking
      // again — about its tool, and about where the repository's git dir is.
      onPollingRecoveryAttempt: source.invalidateCaches,
      budgetReleased: admission.budget.releases(_hostKey()),
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
    ).events;
  }
}
