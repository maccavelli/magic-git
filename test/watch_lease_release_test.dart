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
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
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

/// A handle whose process has already exited with [code] — what a script-level
/// refusal looks like to the arm.
class _ExitedHandle implements CommandStreamHandle {
  _ExitedHandle(this.code);

  final int code;
  // BROADCAST, and that matters. `cancel()` closes these before the arm has
  // subscribed — a refusal is read from `exitCode` and torn down before the
  // stdout listener is set up — and closing an unsubscribed SINGLE-subscription
  // controller returns a future that never completes, so `await handle.cancel()`
  // hangs and the arm never returns. The real handle closes an SSH session and
  // has no such wait; a double that does is testing its own bug.
  final _out = StreamController<String>.broadcast();
  final _err = StreamController<String>.broadcast();

  @override
  Stream<String> get stdout => _out.stream;
  @override
  Stream<String> get stderr => _err.stream;
  @override
  Future<int?> get exitCode async => code;
  @override
  Future<void> cancel() async {
    await _out.close();
    await _err.close();
  }
}

/// Arms against a handle that exited immediately with [code].
class _RefusingExecutor extends SSHCommandExecutor {
  _RefusingExecutor(this.code) : super(SSHClientManager());

  final int code;
  final armed = Completer<void>();

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
  }) async {
    if (!armed.isCompleted) armed.complete();
    return _ExitedHandle(code);
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

/// Waits past the arm's early-exit read.
///
/// Since MADR 0041 phase 3 EVERY arm reads `handle.exitCode` with a 250 ms cap
/// before it commits, so a script-level refusal (no watchable paths, or another
/// watcher holding the repository) is seen as a refusal rather than as a
/// watcher that armed and died. That is a real timer, not a microtask, so
/// `pumpEventQueue()` alone returns before the arm has decided anything.
Future<void> pastEarlyExitRead() =>
    Future<void>.delayed(const Duration(milliseconds: 400));

void main() {
  setUp(RemoteWatchService.resetWatcherCount);
  tearDown(RemoteWatchService.resetWatcherCount);

  Future<_RecordingExecutor> armThenCancel({bool throwOnRemove = false}) async {
    final executor = _RecordingExecutor(throwOnRemove: throwOnRemove);
    final service = RemoteWatchService(executor, hostKey: () => 'host');
    final events = <RepoWatchEvent>[];
    final sub = service.watch('/repo').listen(events.add);
    await executor.armed.future;
    await pastEarlyExitRead();
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

  test('teardown gives the repository lock back, token-guarded', () async {
    // MADR 0043 F3/F4: the next arm for this path waits on the teardown, so
    // the teardown finishing has to mean the lock is actually gone. Closing
    // the channel usually achieves that within a second on its own; this is
    // the part the next arm is allowed to rely on.
    final executor = await armThenCancel();

    final release = executor.commands.where((c) => c.contains('mg-watch.lock'));
    expect(
      release,
      isNotEmpty,
      reason: 'the teardown releases the lock it claimed',
    );
    expect(
      release.single,
      contains('token'),
      reason:
          'guarded by ownership: between deciding to tear down and this '
          'running, another watcher may legitimately have taken the lock, and '
          'removing it would delete a live watcher\'s exclusion',
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

  // MADR 0041 phase 3. The host refuses a second watcher by exit STATUS, and
  // the arm has to read it as a refusal rather than as a watcher that armed and
  // died — the latter spends three restarts before degrading, which is 0022 M6
  // in a different costume.

  test(
    'a locked repository degrades to polling, not to three restarts',
    () async {
      watchDiagnostics.clear();
      final executor = _RefusingExecutor(boundedWatchLockedExit);
      final service = RemoteWatchService(executor, hostKey: () => 'host');
      final events = <RepoWatchEvent>[];
      final sub = service.watch('/repo').listen(events.add);
      await executor.armed.future;
      await pumpEventQueue();
      addTearDown(sub.cancel);

      final records = watchDiagnostics.forRepo('/repo').records;
      expect(
        records.where(
          (r) =>
              r.kind == WatchTransition.armFailed &&
              r.cause.contains('held by another'),
        ),
        isNotEmpty,
        reason:
            'the refusal is named, so "why is this repo polling" is '
            'answerable while it is polling',
      );
      expect(
        records.where((r) => r.kind == WatchTransition.restartScheduled),
        isEmpty,
        reason:
            'a lock is not a blip: retrying just hits the same wall and spends '
            'the restart budget doing it',
      );
      expect(
        events.last.mode,
        WatchMode.polling,
        reason: 'it degrades immediately, and the recovery timer retries later',
      );
      expect(
        RemoteWatchService.liveWatchersFor('host'),
        0,
        reason: 'a refused arm holds no slot',
      );
    },
  );

  test('the bounded no-paths refusal is unchanged by the widened read', () async {
    // Widening the early-exit read to every arm must not change what it already
    // did for bounded ones (0022 M6).
    watchDiagnostics.clear();
    final executor = _RefusingExecutor(boundedWatchNoPathsExit);
    final service = RemoteWatchService(executor, hostKey: () => 'host');
    final sub = service
        .watch(
          '/repo',
          bounded: () async => computeBoundedWatchSpec(
            gitDir: '/repo/.git',
            workTree: '/repo',
            trackedFiles: const [],
          ),
        )
        .listen((_) {});
    await executor.armed.future;
    await pastEarlyExitRead();
    await pumpEventQueue();
    addTearDown(sub.cancel);

    expect(
      watchDiagnostics
          .forRepo('/repo')
          .records
          .where((r) => r.cause == 'no watched paths'),
      isNotEmpty,
    );
    expect(RemoteWatchService.liveWatchersFor('host'), 0);
  });

  test('a recursive arm does not read 97 as a refusal', () async {
    // 97 means "the bounded spec matched no paths", which a recursive arm
    // cannot produce — so it must NOT be read as one there. The condition that
    // keeps them apart is `spec != null`, and this is what fails if it goes.
    watchDiagnostics.clear();
    final executor = _RefusingExecutor(boundedWatchNoPathsExit);
    final service = RemoteWatchService(executor, hostKey: () => 'host');
    final sub = service.watch('/repo').listen((_) {});
    await executor.armed.future;
    await pastEarlyExitRead();
    await pumpEventQueue();
    addTearDown(sub.cancel);

    expect(
      watchDiagnostics
          .forRepo('/repo')
          .records
          .where((r) => r.cause == 'no watched paths'),
      isEmpty,
    );
  });
}
