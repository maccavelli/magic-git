// SSH transport hardening (July 2026 deep-dive):
//  * connect() opens the command and stream handshakes IN PARALLEL (a connect
//    pays max(cmd, stream), not their sum) — pinned by watching two sockets
//    arrive at a stalled fake server before any auth completes;
//  * host-key verification is serialized across those concurrent handshakes
//    (no TOFU double-write, no stacked prompts on the single decision slot);
//  * disconnect() during stalled handshakes force-closes both pending
//    clients and fails the connect promptly;
//  * stream-client redial backoff schedule;
//  * uploadBytes' timeout scales with payload size.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  group('serializeHostKeyVerifier', () {
    test('null verify stays null', () {
      expect(SSHClientManager.serializeHostKeyVerifier(null), isNull);
    });

    test('concurrent verifications run strictly one at a time', () async {
      var active = 0;
      var maxActive = 0;
      final gates = <Completer<bool>>[];
      final serialized = SSHClientManager.serializeHostKeyVerifier((
        type,
        fp,
      ) async {
        active++;
        if (active > maxActive) maxActive = active;
        final gate = Completer<bool>();
        gates.add(gate);
        final decision = await gate.future;
        active--;
        return decision;
      })!;

      final first = Future.value(serialized('ssh-ed25519', Uint8List(0)));
      final second = Future.value(serialized('ssh-ed25519', Uint8List(0)));
      // Let the first verification start; the second must be queued, not
      // running alongside it.
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 1);

      gates[0].complete(true);
      expect(await first, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2, reason: 'second starts only after the first');
      gates[1].complete(false);
      expect(await second, isFalse);
      expect(maxActive, 1);
    });

    test('an error in one verification does not break the chain', () async {
      var calls = 0;
      final serialized = SSHClientManager.serializeHostKeyVerifier((
        type,
        fp,
      ) async {
        calls++;
        if (calls == 1) throw StateError('boom');
        return true;
      })!;

      await expectLater(
        Future.value(serialized('t', Uint8List(0))),
        throwsStateError,
      );
      expect(await Future.value(serialized('t', Uint8List(0))), isTrue);
    });
  });

  test('stream redial backoff: 15s, 30s, 60s, then capped at 120s', () {
    expect(SSHClientManager.streamRedialDelay(0).inSeconds, 15);
    expect(SSHClientManager.streamRedialDelay(1).inSeconds, 30);
    expect(SSHClientManager.streamRedialDelay(2).inSeconds, 60);
    expect(SSHClientManager.streamRedialDelay(3).inSeconds, 120);
    expect(SSHClientManager.streamRedialDelay(4).inSeconds, 120);
  });

  test('upload timeout scales with payload size over the flat default', () {
    expect(
      SSHCommandExecutor.uploadTimeoutFor(0),
      SSHCommandExecutor.defaultTimeout,
    );
    // 6.4 MiB at the 64 KiB/s floor -> +100s on top of the default.
    expect(
      SSHCommandExecutor.uploadTimeoutFor(100 * 64 * 1024),
      SSHCommandExecutor.defaultTimeout + const Duration(seconds: 100),
    );
  });

  test(
    'connect opens both handshakes in parallel, and disconnect force-closes '
    'them and fails the connect promptly',
    () async {
      // A server that accepts TCP but never speaks SSH: both handshakes stall
      // right after their sockets open, so socket arrival order tells us
      // exactly how connect() schedules them.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      final sub = server.listen(accepted.add);
      addTearDown(() async {
        await sub.cancel();
        for (final s in accepted) {
          s.destroy();
        }
        await server.close();
      });

      final manager = SSHClientManager();
      final connecting = manager.connect(
        SSHConnectionProfile(
          host: '127.0.0.1',
          port: server.port,
          username: 'u',
          password: 'p',
        ),
      );
      // Both sockets must arrive while the handshakes are still stalled —
      // sequential dual-client (the old behavior) would never open the second
      // socket before the first client authenticated.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (accepted.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        accepted.length,
        2,
        reason: 'command + stream handshakes must run concurrently',
      );

      // Force-close every pending handshake; the stalled connect must fail
      // now (auth-abort), not after the 15s auth timeout.
      await manager.disconnect();
      await expectLater(connecting, throwsA(anything));
      expect(manager.client, isNull);
      expect(manager.streamClient, isNull);
    },
  );
}
