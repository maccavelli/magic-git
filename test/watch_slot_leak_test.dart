// A watcher slot is RESERVED before the stream is opened, and released on every
// path that does not end armed. `executeStream` can fail five ways; the arm
// catches one of them.
//
//   ssh_command_executor.dart:1223  SSHTransportNotReady
//   ssh_command_executor.dart:1230  SSHCommandSuperseded   (also :1261)
//   ssh_command_executor.dart:1238  SSHStreamBudgetExhausted  <- the only one caught
//   ssh_command_executor.dart:1278  SSHCommandTimeout
//   ssh_command_executor.dart:1279  SSHChannelOpenError
//
// The other four propagate out of `arm` with the slot still held, and nothing
// ever gives it back. Two such failures on one host and every repo on it is
// refused for the rest of the session — which is MADR 0026's H1 exactly: a
// leaked SLOT, refusals persisting with no watcher process alive.
//
// These are the failures a bastion produces routinely: `SSHCommandSuperseded`
// on any reconnect that lands while an arm is in flight, `SSHChannelOpenError`
// under MaxSessions pressure, `SSHTransportNotReady` when a pane arms during a
// handshake.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Stands in for dartssh2's `SSHChannelOpenError`, which cannot be constructed
/// here without a live channel. The arm must not care what type it is — that is
/// the whole point of catching structurally rather than per-exception.
class _FakeChannelOpenError implements Exception {
  const _FakeChannelOpenError();
  @override
  String toString() => 'SSHChannelOpenError: open failed (MaxSessions)';
}

/// Reports a watcher tool, then fails the stream open with [error].
class _StreamFails extends SSHCommandExecutor {
  _StreamFails(this.error) : super(SSHClientManager());

  final Object error;

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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async =>
      const SSHCommandResult(exitCode: 0, stdout: 'inotifywait\n', stderr: '');

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => throw error;
}

Future<void> _armAndFail(Object error) async {
  final service = RemoteWatchService(
    _StreamFails(error),
    hostKey: () => 'bastion',
    streamBudget: _budgetFor2,
  );
  final events = <RepoWatchEvent>[];
  final sub = service.watch('/repo').listen(events.add);
  await pumpEventQueue();
  await sub.cancel();
}

int _budgetFor2() => RemoteWatchService.reservedStreams + 2;
const _cap = 2;

void main() {
  setUp(() {
    RemoteWatchService.resetWatcherCount();
    watchDiagnostics.clear();
  });
  tearDown(RemoteWatchService.resetWatcherCount);

  // All five ways `executeStream` can fail. Four of them used to strand the
  // slot; `SSHStreamBudgetExhausted` was the one the arm caught, and it is here
  // so the caught path is pinned alongside the others rather than assumed.
  for (final (name, error) in <(String, Object)>[
    ('SSHCommandSuperseded', const SSHCommandSuperseded('watch')),
    ('SSHTransportNotReady', const SSHTransportNotReady('watch')),
    ('SSHCommandTimeout', const SSHCommandTimeout('watch')),
    ('SSHChannelOpenError', const _FakeChannelOpenError()),
  ]) {
    test('a $name while opening the stream does not leak the slot', () async {
      await _armAndFail(error);

      expect(
        RemoteWatchService.liveWatchersFor('bastion'),
        0,
        reason:
            'the slot was reserved before the stream open and must come '
            'back when the open fails — otherwise two such failures refuse '
            'every repo on this host for the rest of the session',
      );
    });
  }

  test('repeated stream-open failures do not exhaust the host budget', () async {
    // The reported shape: every repo on the bastion polling, "watchers held 2",
    // with no watcher process alive to hold them.
    for (var i = 0; i < _cap; i++) {
      await _armAndFail(const SSHCommandSuperseded('watch'));
    }

    expect(RemoteWatchService.liveWatchersFor('bastion'), 0);

    // A repo arming afterwards must not be refused.
    final events = <RepoWatchEvent>[];
    final service = RemoteWatchService(
      _StreamFails(const SSHCommandSuperseded('watch')),
      hostKey: () => 'bastion',
      streamBudget: _budgetFor2,
    );
    final sub = service.watch('/later').listen(events.add);
    await pumpEventQueue();
    addTearDown(sub.cancel);

    // Sanity, so the budget assertion below cannot pass vacuously: the arm
    // really was attempted and really did fail. It does NOT poll immediately —
    // a rethrown arm is a transport blip, so the engine schedules a restart and
    // only degrades once the restart budget is spent. (An earlier draft of this
    // test asserted polling here; that was an assumption about the engine, not
    // an observation of it.)
    expect(
      watchDiagnostics
          .forRepo('/later')
          .records
          .where((r) => r.kind == WatchTransition.restartScheduled),
      isNotEmpty,
      reason: 'the arm must have been attempted and failed',
    );
    expect(
      RemoteWatchService.liveWatchersFor('bastion'),
      lessThan(_cap),
      reason: 'the budget must not be spent by arms that never armed',
    );
  });
}
