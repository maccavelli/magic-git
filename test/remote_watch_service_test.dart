import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
  }) async {
    return const SSHCommandResult(exitCode: 0, stdout: 'none\n', stderr: '');
  }
}

/// Reports fswatch available, but fails every attempt to actually open the
/// streaming channel — exercises the "watcher tool detected but the channel
/// itself never comes up" path without needing a real, unmockable
/// SSHStreamHandle (its constructor is private).
class _ThrowingStreamExecutor extends SSHCommandExecutor {
  _ThrowingStreamExecutor() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
  }) async {
    return const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) async {
    throw Exception('cannot open watcher channel');
  }
}

void main() {
  test('falls back to polling when no watcher tool is available', () {
    fakeAsync((async) {
      final service = RemoteWatchService(_FakeExecutor());
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch('/repo', pollInterval: const Duration(seconds: 5))
          .listen(events.add);

      async.elapse(Duration.zero);
      expect(events, isNotEmpty);
      expect(events.last.mode, WatchMode.polling);

      async.elapse(const Duration(seconds: 5));
      expect(events.length, greaterThanOrEqualTo(2));

      sub.cancel();
    });
  });

  test(
    'a failed watcher start surfaces `stopped` immediately, not silently '
    'through the whole restart backoff window',
    () {
      fakeAsync((async) {
        final service = RemoteWatchService(_ThrowingStreamExecutor());
        final events = <RepoWatchEvent>[];
        final sub = service.watch('/repo').listen(events.add);

        // The channel-open fails right away; before the fix, nothing was ever
        // emitted here — subscribers would see no event at all through the
        // entire restart backoff, previously indistinguishable from "still
        // fine" (whatever mode a consumer's UI last rendered).
        async.elapse(Duration.zero);
        expect(events, isNotEmpty);
        expect(events.last.mode, WatchMode.stopped);

        sub.cancel();
      });
    },
  );
}
