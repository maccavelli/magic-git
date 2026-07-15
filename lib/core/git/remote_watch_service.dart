import 'dart:async';
import 'dart:developer' as developer;
import '../ssh/ssh_command_executor.dart';
import 'watch_event.dart';
import 'watch_lifecycle.dart';
import 'watch_path_filter.dart';

enum _WatcherTool { fswatch, inotifywait, none }

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

  Stream<RepoWatchEvent> watch(
    String repoPath, {
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
    _WatcherTool? cachedTool;

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

        if (tool == _WatcherTool.none) return const WatchUnavailable();

        final handle = await _executor.executeStream(
          repoPath: repoPath,
          gitArgs: _watcherArgs(tool),
        );
        if (hooks.isCancelled()) {
          await handle.cancel();
          return const WatchAborted();
        }

        var buffer = '';
        final delimiter = tool == _WatcherTool.fswatch ? '\u0000' : '\n';
        final sub = handle.stdout.listen(
          (chunk) {
            hooks.noteActivity();
            buffer += chunk;
            var idx = buffer.indexOf(delimiter);
            while (idx >= 0) {
              final event = buffer.substring(0, idx);
              buffer = buffer.substring(idx + 1);
              if (shouldTriggerWatch(event)) {
                hooks.signalPath(event);
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
          // Cancel the stdout subscription *before* the handle, mirroring the
          // engine's source-before-coalescer ordering.
          await sub.cancel();
          await handle.cancel();
        });
      },
    );
  }

  Future<_WatcherTool> _detectWatcher(String repoPath) async {
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
        return _WatcherTool.fswatch;
      case 'inotifywait':
        return _WatcherTool.inotifywait;
      default:
        return _WatcherTool.none;
    }
  }

  List<String> _watcherArgs(_WatcherTool tool) {
    switch (tool) {
      case _WatcherTool.fswatch:
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
      case _WatcherTool.inotifywait:
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
              '-e modify,create,delete,move --format %w%f .; '
              'else exec inotifywait -m -r '
              '-e modify,create,delete,move --format %w%f .; fi',
        ];
      case _WatcherTool.none:
        return const [];
    }
  }
}
