import 'dart:async';
import 'dart:developer' as developer;
import '../ssh/ssh_command_executor.dart';
import 'bounded_watch.dart';
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
  BoundedWatchSpec? bounded,
) {
  // Scoped work-tree repo: watch the explicit, non-recursive bounded surface
  // (git-dir points + tracked-file dirs) instead of the whole work tree.
  if (bounded != null) {
    switch (tool) {
      case RemoteWatcherTool.fswatch:
        // Through `sh -c` like the inotify twin: fswatch needs the same
        // existence filter (see boundedFswatchScript).
        return ['sh', '-c', boundedFswatchScript(bounded.watchDirs)];
      case RemoteWatcherTool.inotifywait:
        return ['sh', '-c', boundedInotifyScript(bounded.watchDirs)];
      case RemoteWatcherTool.none:
        return const [];
    }
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

  RemoteWatchService(this._executor);

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

    return watchLifecycle(
      trailing: trailing,
      maxWait: maxWait,
      minInterval: minInterval,
      pollInterval: pollInterval,
      recoveryInterval: recoveryInterval,
      onPollingRecoveryAttempt: () => cachedTool = null,
      arm: (hooks) async {
        final tool = cachedTool ??= await _detectWatcher(repoPath);
        if (hooks.isCancelled()) return const WatchAborted();

        if (tool == RemoteWatcherTool.none) return const WatchUnavailable();

        // Resolve the bounded surface HERE, on every arm, rather than closing
        // over one computed once for the stream's life. The tracked-file set
        // changes constantly on a dotfiles repo, and a frozen surface meant a
        // file staged into a directory nothing was watching yet never produced
        // an event again until the whole provider was torn down (0022 H5).
        final spec = bounded == null ? null : await bounded();
        if (hooks.isCancelled()) return const WatchAborted();

        final handle = await _executor.executeStream(
          repoPath: repoPath,
          gitArgs: remoteWatcherArgs(tool, spec),
        );
        if (hooks.isCancelled()) {
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
            await handle.cancel();
            return const WatchUnavailable();
          }
        }

        var buffer = '';
        final delimiter = tool == RemoteWatcherTool.fswatch ? '\u0000' : '\n';
        final sub = handle.stdout.listen(
          (chunk) {
            hooks.noteActivity();
            buffer += chunk;
            var idx = buffer.indexOf(delimiter);
            while (idx >= 0) {
              final event = buffer.substring(0, idx);
              buffer = buffer.substring(idx + 1);
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
              idx = buffer.indexOf(delimiter);
            }
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

        return WatchArmed(() async {
          rearmTimer?.cancel();
          rearmTimer = null;
          // Cancel the stdout subscription *before* the handle, mirroring the
          // engine's source-before-coalescer ordering.
          await sub.cancel();
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
    );
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
