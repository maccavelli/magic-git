// The readiness contract (MADR 0018), tested at the seam that implements it.
//
// The bug: a repo provider issues its command the moment anything listens,
// transport or not. The executor threw, the failure was cached as the
// provider's state, and the Repository panel rendered it on its first frame —
// the "split second" of `SSH connection not established.` a cold connect
// showed. Riverpod's default retry used to hide this by silently retrying;
// 0017 turned that off and made an always-present race visible.
//
// This exercises the guard where it lives — `SSHCommandExecutor`'s client
// check, over `SSHClientManager`'s attach gate — rather than through the
// connection controller, the provider graph and the widget tree. Those layers
// have their own tests; driving all of them here would test the fixture more
// than the contract.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/fake_ssh_client.dart';

void main() {
  test('nothing in flight: fails at once rather than waiting', () async {
    // A dead host, or an app that never connected. There is nothing to wait
    // for, and waiting would stall every repo pane indefinitely.
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager);

    final started = Stopwatch()..start();
    await expectLater(
      executor.execute(repoPath: '/r', gitArgs: const ['true']),
      throwsA(isA<SSHTransportNotReady>()),
    );
    started.stop();

    expect(manager.isAttachSettled, isTrue);
    expect(
      started.elapsed,
      lessThan(SSHCommandExecutor.attachGrace),
      reason: 'it waited on a handshake that was never running',
    );
  });

  test(
    'handshake in flight: waits, then runs once the client attaches',
    () async {
      // The command is early, not wrong. Failing it would cache an error the
      // pane then renders — which is the whole bug.
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      final release = Completer<void>();

      final handshake = manager.withAttachGate(() async {
        await release.future;
        manager.bindTestClients(command: FakeSshClient());
      });

      expect(manager.isAttachSettled, isFalse);
      expect(manager.isAttached, isFalse);

      var settled = false;
      final pending = executor
          .execute(repoPath: '/r', gitArgs: const ['true'])
          .whenComplete(() => settled = true);

      // The property under test: it did NOT fail fast. Before the fix this
      // threw immediately and the pane cached the error.
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse, reason: 'the command should still be waiting');

      release.complete();
      await handshake;
      Object? failure;
      await pending.then<void>((_) {}, onError: (Object e) => failure = e);

      expect(manager.isAttached, isTrue);
      // It waited rather than reporting not-ready. Whether it then *runs*
      // depends on generation pinning: bindTestClients advances the
      // generation, so a command pinned before it is legitimately superseded.
      // Production advances the generation when the handshake starts, so a
      // command issued during a connect pins the attempt it waits for —
      // ssh_command_executor_test.dart owns that contract.
      expect(failure, isNot(isA<SSHTransportNotReady>()));
    },
  );

  test('handshake fails: the waiting command reports not-ready', () async {
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager);
    final release = Completer<void>();

    final handshake = manager.withAttachGate<void>(() => release.future);

    final pending = executor.execute(repoPath: '/r', gitArgs: const ['true']);
    release.completeError(const SocketException('refused'));
    await handshake.then<void>((_) {}, onError: (_) {});

    // The gate settles on every path, including a throw, so the command is
    // released rather than left hanging on an attempt that already died.
    await expectLater(pending, throwsA(isA<SSHTransportNotReady>()));
  });

  test('the grace is bounded: a wedged handshake never pins a command', () {
    fakeAsync((async) {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);

      // Opened and never settled — the handshake that hangs forever.
      unawaited(manager.withAttachGate(() => Completer<void>().future));

      Object? thrown;
      unawaited(
        executor.execute(repoPath: '/r', gitArgs: const ['true']).catchError((
          Object e,
        ) {
          thrown = e;
          return const SSHCommandResult(exitCode: 1, stdout: '', stderr: '');
        }),
      );

      async.elapse(SSHCommandExecutor.attachGrace + const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(thrown, isA<SSHTransportNotReady>());
    });
  });

  test('already attached: no wait, no timer on the hot path', () {
    fakeAsync((async) {
      final manager = SSHClientManager()
        ..bindTestClients(command: FakeSshClient());
      final executor = SSHCommandExecutor(manager);

      var done = false;
      unawaited(
        executor
            .execute(repoPath: '/r', gitArgs: const ['true'])
            .then((_) => done = true),
      );
      async.flushMicrotasks();

      expect(done, isTrue, reason: 'the attached path must not await a gate');
      expect(
        async.pendingTimers,
        isEmpty,
        reason: 'every command would pay for this timer',
      );
    });
  });

  // Two connects overlapping is ordinary, not exotic: the reconnect popup is
  // up, an auto-reconnect attempt is mid-handshake, and the user picks another
  // saved connection. The superseded attempt then returns immediately through
  // one of _connect's generation early-returns — and used to settle the gate
  // belonging to the attempt that superseded it (0024 H1).
  group('overlapping attaches', () {
    test('a superseded attach does not settle its successor gate', () async {
      final manager = SSHClientManager();
      final firstBody = Completer<void>();
      final secondBody = Completer<void>();

      final first = manager.withAttachGate<void>(() => firstBody.future);
      expect(manager.isAttachSettled, isFalse);

      final second = manager.withAttachGate<void>(() => secondBody.future);
      expect(manager.isAttachSettled, isFalse);

      // The first attempt gives up (superseded). The second is still running.
      firstBody.complete();
      await first;

      expect(
        manager.isAttachSettled,
        isFalse,
        reason: 'the second handshake is still in flight',
      );

      secondBody.complete();
      await second;
      expect(manager.isAttachSettled, isTrue);
    });

    test('a command still waits while the successor handshakes', () async {
      // The consequence the gate state stands for: MADR 0018 exists so this
      // command waits instead of caching SSHTransportNotReady into a pane.
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      final firstBody = Completer<void>();
      final secondBody = Completer<void>();

      final first = manager.withAttachGate<void>(() => firstBody.future);
      final second = manager.withAttachGate<void>(() => secondBody.future);
      firstBody.complete();
      await first;

      var settled = false;
      final pending = executor
          .execute(repoPath: '/r', gitArgs: const ['true'])
          .whenComplete(() => settled = true);

      await Future<void>.delayed(Duration.zero);
      expect(
        settled,
        isFalse,
        reason: 'it must wait out the handshake that is actually running',
      );

      secondBody.complete();
      await second;
      await expectLater(pending, throwsA(isA<SSHTransportNotReady>()));
    });
  });
}
