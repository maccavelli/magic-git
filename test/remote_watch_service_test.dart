import 'dart:async';

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
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
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
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    return const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    throw Exception('cannot open watcher channel');
  }
}

/// A live-but-silent stream handle: the watcher channel opens fine and then
/// just never emits (no file changes). Lets a test hold the service in
/// event-driven mode.
class _SilentStreamHandle implements SSHStreamHandle {
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();

  @override
  Stream<String> get stdout => _stdout.stream;
  @override
  Stream<String> get stderr => _stderr.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    if (!_stdout.isClosed) await _stdout.close();
    if (!_stderr.isClosed) await _stderr.close();
  }
}

/// Reports no watcher tool on the first probe (degrading the service to
/// polling), then fswatch on every later probe with a working channel — the
/// "recovered from polling" path.
class _RecoveringExecutor extends SSHCommandExecutor {
  _RecoveringExecutor() : super(SSHClientManager());

  int probes = 0;

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    final tool = probes++ == 0 ? 'none' : 'fswatch';
    return SSHCommandResult(exitCode: 0, stdout: '$tool\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    return _SilentStreamHandle();
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

  test('recovering from polling back to event-driven stops the poll ticks '
      '(regression: the poll timer used to leak and fire forever)', () {
    fakeAsync((async) {
      final service = RemoteWatchService(_RecoveringExecutor());
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch(
            '/repo',
            pollInterval: const Duration(seconds: 5),
            recoveryInterval: const Duration(seconds: 30),
          )
          .listen(events.add);

      // First probe finds no tool → polling mode, ticking every 5s.
      async.elapse(Duration.zero);
      expect(events.last.mode, WatchMode.polling);
      async.elapse(const Duration(seconds: 29));
      expect(events.length, greaterThanOrEqualTo(5));

      // Recovery probe finds fswatch and the channel opens → event-driven.
      async.elapse(const Duration(seconds: 2));
      expect(events.last.mode, WatchMode.eventDriven);
      final atRecovery = events.length;

      // No file changes arrive; a leaked poll timer would keep emitting a
      // tick (each one a status round trip) every 5s regardless.
      async.elapse(const Duration(seconds: 60));
      expect(
        events.length,
        atRecovery,
        reason: 'poll timer must be cancelled once event-driven recovers',
      );

      sub.cancel();
    });
  });

  test('a failed watcher start surfaces `stopped` immediately, not silently '
      'through the whole restart backoff window', () {
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
  });
}
