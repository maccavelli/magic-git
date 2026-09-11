import '../../../../ssh/ssh_command_executor.dart';
import '../../../remote_watch_service.dart' show RemoteWatcherTool;

/// Which watcher tool the host has, asked once per watcher's life.
///
/// Cached across restarts: the answer cannot change between one blip's
/// retries, so there is no need to re-probe the host for it every time.
/// [invalidate] clears it while recovering from polling, since enough time has
/// passed there that it is worth asking again.
final class WatcherToolProbe {
  WatcherToolProbe(this._executor);

  final CommandExecutor _executor;
  RemoteWatcherTool? _cached;

  /// The host's watcher tool for [repoPath]. Throws if the probe itself fails.
  Future<RemoteWatcherTool> tool(String repoPath) async =>
      _cached ??= await _detect(repoPath);

  /// Forgets the cached answer, so the next [tool] asks the host again.
  void invalidate() => _cached = null;

  Future<RemoteWatcherTool> _detect(String repoPath) async {
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
    // (0024 M3). Throwing lets the engine's restart budget retry in seconds —
    // which is what it is for — and nothing is cached, because the assignment
    // in [tool] never completes.
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
