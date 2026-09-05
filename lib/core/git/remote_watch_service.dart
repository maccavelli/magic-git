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

/// Exclude git internals that flood a recursive watch during fetch/gc.
/// Shared by both sides of the `stdbuf` / bare `inotifywait` fork.
const _inotifyExcludeFlags =
    r"--exclude '/\.git/objects/' "
    r"--exclude '/\.git/logs/' "
    r"--exclude '\.lock$' "
    r"--exclude '/\.git/fsmonitor--daemon/' ";

/// Argv for the remote watcher process. Extracted so tests can assert
/// inotifywait excludes without arming an SSH stream.
List<String> remoteWatcherArgs(
  RemoteWatcherTool tool,
  BoundedWatchSpec? bounded, {
  String? pidFile,
  String? heartbeat,
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
        pidFile: pidFile,
        heartbeat: heartbeat,
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
            '--format %w%f .; '
            'else exec inotifywait -m -r '
            '-e modify,create,delete,move $_inotifyExcludeFlags'
            '--format %w%f .; fi',
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
/// The restart/polling/recovery lifecycle lives in [watchLifecycle], shared
/// with `LocalWatchService`; this class owns only the remote-specific arming:
/// tool detection, the SSH stream, and delimiter parsing.
class RemoteWatchService {
  final CommandExecutor _executor;

  RemoteWatchService(this._executor, {this.onDiagnostic});

  /// Where a watcher's own stderr goes.
  final void Function(String line)? onDiagnostic;

  /// Diagnostic lines reported per arm.
  static const int maxDiagnosticLines = 20;

  /// Live watcher processes one connection may hold at once.
  ///
  /// One active repo plus one background. Past this the app polls and says so,
  /// rather than accumulating — 19 orphaned `inotifywait` processes, the
  /// oldest 16.9 days, is what "no ceiling at all" produced (0025 C3).
  static const int maxConcurrentWatchers = 2;

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

  /// The pre-0027 single-file scheme, still present on hosts that ran an
  /// earlier build. Phase 4 reclaims what it left; nothing writes these.
  static String legacyWatchPidFile(String gitDir) => '$gitDir/mg-watch.pid';
  static String legacyWatchHeartbeatFile(String gitDir) =>
      '$gitDir/mg-watch.hb';

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
            watcherSweepScript(
              [legacyWatchPidFile(entry.value)],
              heartbeat: legacyWatchHeartbeatFile(entry.value),
              staleAfter: leaseStaleAfter,
            ),
          ],
          lane: ExecLane.isolated,
          timeout: const Duration(seconds: 20),
        );
      } catch (e) {
        onDiagnostic?.call('watcher sweep failed for ${entry.key}: $e');
      }
    }
  }

  /// Live watcher processes this client has armed. Static because the ceiling
  /// is a property of the *host* budget, not of any one service instance —
  /// several providers construct their own service against the same host.
  static int _liveWatchers = 0;

  /// Live watcher count — for tests and diagnostics.
  static int get liveWatchers => _liveWatchers;

  /// Test seam: the counter is process-global, so a test that arms watchers
  /// must be able to start from a known state.
  @visibleForTesting
  static void resetWatcherCount() => _liveWatchers = 0;

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
          liveWatchers: _liveWatchers,
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
  /// [bounded], when supplied, switches to the **scoped work-tree** surface for
  /// a dotfiles-style repo (git-dir + tracked-file dirs, non-recursive) instead
  /// of a recursive watch of the whole work tree — see [BoundedWatchSpec] for
  /// why a recursive `$HOME` watch is unacceptable. Only pass it when the repo's
  /// type toggle marks it as such; an ordinary repo leaves it null and gets the
  /// unchanged recursive behaviour.
  Stream<RepoWatchEvent> watch(
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
          return const WatchUnavailable();
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
        if (_liveWatchers >= maxConcurrentWatchers) {
          onDiagnostic?.call(
            'watcher ceiling reached ($_liveWatchers/$maxConcurrentWatchers) — '
            'polling $repoPath instead',
          );
          _record(
            repoPath,
            WatchTransition.armFailed,
            'ceiling $_liveWatchers/$maxConcurrentWatchers',
            0,
          );
          return const WatchUnavailable();
        }
        // RESERVE the slot here, synchronously, rather than counting it once
        // the arm succeeds. Arms are concurrent — several repos arm at once on
        // connect — and every one of them awaits the tool probe before this
        // point, so a check that did not reserve let all of them pass the
        // ceiling together. Released on every path that does not end armed.
        _liveWatchers++;
        var armCounted = true;
        void releaseSlot() {
          if (!armCounted) return;
          armCounted = false;
          if (_liveWatchers > 0) _liveWatchers--;
        }

        final CommandStreamHandle handle;
        try {
          handle = await _executor.executeStream(
            repoPath: repoPath,
            gitArgs: remoteWatcherArgs(
              tool,
              spec,
              pidFile: watchPidFile(spec?.gitDir ?? '$repoPath/.git', token),
              heartbeat: watchHeartbeatFile(
                spec?.gitDir ?? '$repoPath/.git',
                token,
              ),
            ),
          );
        } on SSHStreamBudgetExhausted catch (e) {
          releaseSlot();
          // Deterministic, not a blip: retrying just hits the same wall and
          // spends the restart budget doing it. Poll this repo instead, and
          // say why (0024 M2).
          onDiagnostic?.call('$e — falling back to polling for this repo');
          _record(repoPath, WatchTransition.armFailed, 'stream budget', 0);
          return const WatchUnavailable();
        }
        if (hooks.isCancelled()) {
          releaseSlot();
          await handle.cancel();
          return const WatchAborted();
        }

        if (spec != null) {
          // The bounded scripts exit immediately with a distinct status when
          // none of their paths exist yet. Catch that here so it degrades to
          // polling-with-recovery instead of looking like a watcher that armed
          // and died — which would spend the restart budget on three doomed
          // retries first (0022 M6). Bounded arms only, and the wait is capped:
          // a live watcher never completes exitCode, so this costs one short
          // timeout on a path that already paid for an SSH round trip.
          final early = await handle.exitCode.timeout(
            const Duration(milliseconds: 250),
            onTimeout: () => null,
          );
          if (early == boundedWatchNoPathsExit) {
            releaseSlot();
            await handle.cancel();
            _record(repoPath, WatchTransition.armFailed, 'no watched paths', 0);
            return const WatchUnavailable();
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
          onDone: hooks.scheduleRestart,
          onError: (Object _) => hooks.scheduleRestart(),
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
        final gitDir = spec?.gitDir ?? '$repoPath/.git';
        final heartbeat = watchHeartbeatFile(gitDir, token);
        Future<void> beat() async {
          try {
            await _executor.execute(
              repoPath: repoPath,
              gitArgs: ['sh', '-c', 'touch ${ShellEscaper.escape(heartbeat)}'],
              lane: ExecLane.isolated,
              timeout: const Duration(seconds: 15),
            );
          } catch (_) {
            // Best-effort. A missed beat costs nothing until leaseStaleAfter.
          }
        }

        unawaited(beat());
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
            if (line.isNotEmpty && diagnosticsSeen < maxDiagnosticLines) {
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
        });
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
