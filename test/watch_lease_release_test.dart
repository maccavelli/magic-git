// MADR 0041, phase 2. The client owns the lease it wrote, so it removes it.
//
// Closing the channel is the fast path — the watcher's stdin reaches EOF and it
// is gone within a second (proven against real processes in
// watch_lease_teardown_exec_test.dart). This is the case that path cannot cover:
// a channel that died without the host noticing, where the watcher would
// otherwise sit until `leaseStaleAfter` elapsed. Removing the heartbeat ends it
// at the next lease poll instead.
//
// The second test is the one that matters. A teardown runs during disconnects,
// which is exactly when the executor has nothing to talk to — so a removal that
// throws must be invisible to the caller. If it is not, every disconnect
// surfaces an error from a best-effort cleanup.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A stream handle that stays open until it is cancelled.
class _OpenHandle implements CommandStreamHandle {
  final _out = StreamController<String>();
  final _err = StreamController<String>();
  final _exit = Completer<int?>();
  var cancelled = false;

  @override
  Stream<String> get stdout => _out.stream;
  @override
  Stream<String> get stderr => _err.stream;
  @override
  Future<int?> get exitCode => _exit.future;
  @override
  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    if (!_exit.isCompleted) _exit.complete(null);
    await _out.close();
    await _err.close();
  }
}

/// Records every one-shot command, and optionally throws on the removal.
class _RecordingExecutor extends SSHCommandExecutor {
  _RecordingExecutor({this.throwOnRemove = false}) : super(SSHClientManager());

  final bool throwOnRemove;
  final handle = _OpenHandle();
  final armed = Completer<void>();
  final commands = <String>[];

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
  }) async {
    final joined = gitArgs.join(' ');
    commands.add(joined);
    if (throwOnRemove && joined.contains('rm -f')) {
      throw const SSHTransportNotReady('rm');
    }
    // Anything that is not the tool probe is a lease touch or removal.
    if (joined.contains('command -v')) {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: 'inotifywait\n',
        stderr: '',
      );
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
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
    if (!armed.isCompleted) armed.complete();
    return handle;
  }
}

/// The heartbeat token this arm chose, read back out of the arm's own commands.
String? _leaseTouched(List<String> commands) {
  for (final c in commands) {
    if (c.startsWith('sh -c touch ')) return c;
  }
  return null;
}

void main() {
  setUp(RemoteWatchService.resetWatcherCount);
  tearDown(RemoteWatchService.resetWatcherCount);

  Future<_RecordingExecutor> armThenCancel({bool throwOnRemove = false}) async {
    final executor = _RecordingExecutor(throwOnRemove: throwOnRemove);
    final service = RemoteWatchService(executor, hostKey: () => 'host');
    final events = <RepoWatchEvent>[];
    final sub = service.watch('/repo').listen(events.add);
    await executor.armed.future;
    await pumpEventQueue();
    await sub.cancel();
    await pumpEventQueue();
    return executor;
  }

  test('teardown removes the lease this arm stamped', () async {
    final executor = await armThenCancel();

    final touch = _leaseTouched(executor.commands);
    expect(
      touch,
      isNotNull,
      reason: 'the arm stamps its lease before arming — 0027 deviation (b)',
    );
    // The token is what makes this the arm's OWN lease rather than the repo's.
    final hb = RegExp(r'mg-watch\.[\w]+\.hb').firstMatch(touch!)!.group(0);

    expect(
      executor.commands.where((c) => c.contains('rm -f') && c.contains(hb!)),
      isNotEmpty,
      reason:
          'the client wrote this heartbeat, so the client removes it — '
          'otherwise the watcher waits out leaseStaleAfter (0041 F2)',
    );
  });

  test(
    'teardown never removes the pid file, which is the watcher\'s',
    () async {
      final executor = await armThenCancel();

      expect(
        executor.commands.where(
          (c) => c.contains('rm -f') && c.contains('.pid'),
        ),
        isEmpty,
        reason:
            'ownership is split so a half-dead pair stays the shape the sweep '
            'reclaims: the watcher removes what the watcher wrote',
      );
    },
  );

  test('a removal that throws does not fail the teardown', () async {
    // The realistic case: teardown during a disconnect, with no transport left.
    //
    // Reaching the end of this test IS the assertion. The removal is
    // unawaited, so an escaping error arrives as an unhandled asynchronous
    // exception, which the test runner fails on — there is nowhere for it to
    // hide. Deleting the `catch` in `releaseLease` is what proves that, and
    // the mutation catalogue does exactly that.
    final executor = await armThenCancel(throwOnRemove: true);
    await pumpEventQueue();

    expect(
      executor.commands.where((c) => c.contains('rm -f')),
      isNotEmpty,
      reason: 'it was attempted — so this test is not vacuously green',
    );
  });
}
