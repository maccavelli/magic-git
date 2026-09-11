import 'dart:async';

import '../../../../ssh/shell_escaper.dart';
import '../../../../ssh/ssh_command_executor.dart';
import '../../../bounded_watch.dart';
import '../../../remote_watch_service.dart' show RemoteWatchService;
import '../../watch_timings.dart';

/// The lease could not be stamped, so no watcher may be started for it.
final class WatchLeaseException implements Exception {
  const WatchLeaseException(this.message);
  final String message;

  @override
  String toString() => 'WatchLeaseException: $message';
}

/// One watcher instance's claims on the host: its lease, and — while it owns
/// it — the repository lock.
///
/// Ownership is split on purpose. The CLIENT writes the heartbeat and removes
/// it; the WATCHER writes its pid file and its own cleanup removes that. Neither
/// touches the other's, so a half-dead pair is still exactly the shape the
/// connect-time sweep reclaims.
final class WatchLease {
  WatchLease({
    required this.executor,
    required this.repoPath,
    required this.gitDir,
    required this.token,
    required this.timings,
  });

  /// Where the host commands go.
  final CommandExecutor executor;
  final String repoPath;

  /// The resolved git dir the host script locks and keeps its files in.
  final String gitDir;

  /// This watcher instance's identity; every re-arm gets a new one (0027).
  final String token;
  final WatchTimings timings;

  Timer? _heartbeat;

  /// The watcher's registry file, written and removed by the watcher itself.
  String get pidFile => RemoteWatchService.watchPidFile(gitDir, token);

  /// The lease file: the client's proof that it is alive.
  String get heartbeatFile =>
      RemoteWatchService.watchHeartbeatFile(gitDir, token);

  /// The host lock this instance claims.
  WatchLock get lock => (gitDir: gitDir, token: token);

  /// Stamps the lease. Awaited BEFORE the watcher is started, because the
  /// watcher's first act is `[ -f <heartbeat> ] || exit 0` (0027 deviation
  /// (b)).
  ///
  /// Throws [WatchLeaseException] with the host's reason when the stamp is
  /// refused. It used to be swallowed like every later beat, so a stamp that
  /// failed opened a stream whose watcher exited at once — spending a restart
  /// to learn what the command had already said.
  Future<void> stamp() async {
    final result = await _touch();
    if (!result.isSuccess) {
      throw WatchLeaseException(
        'could not stamp the watcher lease ${result.exitCode}: '
        '${result.stderr.trim()}',
      );
    }
  }

  /// Refreshes the lease every `timings.heartbeatInterval` until
  /// [stopHeartbeat]. Best-effort: a missed beat costs nothing until
  /// `leaseStaleAfter`.
  void startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(timings.heartbeatInterval, (_) async {
      try {
        await _touch();
      } catch (_) {
        // Best-effort, as above.
      }
    });
  }

  /// Stops refreshing the lease.
  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Gives back the lease, and the lock while this token still owns it.
  ///
  /// Best-effort by construction. The common failure is a disconnected
  /// executor, which is also the case where the watcher has already taken
  /// stdin EOF and released these itself; nothing to report and nothing to
  /// retry.
  ///
  /// **The `releaseTimeout` is load-bearing and coupled to the admission
  /// grace.** This session's next watcher of the repository waits for the
  /// exclusion released after this call; because this call cannot take longer
  /// than its own timeout, that grace is a backstop that should never be
  /// reached — `WatchTimings.coherenceErrors` asserts the pair.
  Future<void> releaseHostClaims() async {
    try {
      await executor.execute(
        repoPath: repoPath,
        gitArgs: [
          'sh',
          '-c',
          'rm -f ${ShellEscaper.escape(heartbeatFile)}; '
              '${watchLockReleaseScript(lock)}',
        ],
        lane: ExecLane.isolated,
        timeout: timings.releaseTimeout,
      );
    } catch (_) {
      // See the doc comment: swallowing is the contract, not an oversight.
    }
  }

  Future<SSHCommandResult> _touch() => executor.execute(
    repoPath: repoPath,
    gitArgs: ['sh', '-c', 'touch ${ShellEscaper.escape(heartbeatFile)}'],
    lane: ExecLane.isolated,
    timeout: timings.releaseTimeout,
  );
}
