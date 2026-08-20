// Regression coverage for SSHCommandExecutor's connection-generation pinning
// (a command queued before a reconnect/disconnect must refuse to run against
// whatever connection happens to be current by the time its turn comes up,
// not silently execute against it) and SSHClientManager's generation
// bookkeeping, which the pinning depends on. Uses a real (unfaked)
// SSHClientManager throughout — no live socket is needed for these cases
// since the assertions never depend on a client actually being connected.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_telemetry.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  group('SSHClientManager generation + dual-client surface', () {
    test('starts at 0 and is bumped by disconnect even with no connection', () {
      final manager = SSHClientManager();
      expect(manager.generation, 0);
      manager.disconnect();
      expect(manager.generation, 1);
      manager.disconnect();
      expect(manager.generation, 2);
    });

    test('disconnected dual-client getters are null / not degraded', () {
      final manager = SSHClientManager();
      expect(manager.client, isNull);
      expect(manager.streamClient, isNull);
      expect(manager.syncClient, isNull);
      expect(manager.streamClientDegraded, isFalse);
      expect(manager.syncClientDegraded, isFalse);
      expect(manager.attachedClientCount, 0);
      expect(manager.clientGeneration, -1);
      expect(manager.done, isNull);
    });

    test(
      'disconnect clears clientGeneration and keeps streamClient null',
      () async {
        final manager = SSHClientManager();
        await manager.disconnect();
        expect(manager.client, isNull);
        expect(manager.streamClient, isNull);
        expect(manager.clientGeneration, -1);
        expect(manager.streamClientDegraded, isFalse);
      },
    );
  });

  group('SSHCommandExecutor adaptive read concurrency', () {
    test('starts at the adaptive no-sample cap (3)', () {
      final executor = SSHCommandExecutor(SSHClientManager());
      expect(executor.adaptiveReadCap, 3);
    });

    test('noteLinkRtt lowers the cap after hysteresis', () {
      final executor = SSHCommandExecutor(SSHClientManager());
      for (var i = 0; i < 3; i++) {
        executor.noteLinkRtt(const Duration(milliseconds: 300));
      }
      expect(executor.adaptiveReadCap, 2);
    });

    test('resetAdaptiveReads and resetEnvironment restore no-sample cap', () {
      final executor = SSHCommandExecutor(SSHClientManager());
      for (var i = 0; i < 3; i++) {
        executor.noteLinkRtt(const Duration(milliseconds: 300));
      }
      expect(executor.adaptiveReadCap, 2);

      executor.resetAdaptiveReads();
      expect(executor.adaptiveReadCap, 3);

      for (var i = 0; i < 3; i++) {
        executor.noteLinkRtt(const Duration(milliseconds: 300));
      }
      expect(executor.adaptiveReadCap, 2);
      executor.resetEnvironment();
      expect(executor.adaptiveReadCap, 3);
    });

    test('low RTT raises cap back to the production ceiling of 4', () {
      final executor = SSHCommandExecutor(SSHClientManager());
      // First settle at 2, then recover.
      for (var i = 0; i < 3; i++) {
        executor.noteLinkRtt(const Duration(milliseconds: 300));
      }
      for (var i = 0; i < 3; i++) {
        executor.noteLinkRtt(const Duration(milliseconds: 20));
      }
      expect(executor.adaptiveReadCap, 4);
    });
  });

  group(
    'SSHCommandExecutor pins each command to its enqueue-time generation',
    () {
      test('a command already queued when a disconnect happens is refused, '
          'not silently run against the new state', () async {
        final manager = SSHClientManager();
        final executor = SSHCommandExecutor(manager);

        // First command: no connection exists, so it fails immediately with
        // the ordinary "not established" error. This just anchors queue
        // ordering — the executor serializes commands strictly in order, so
        // the second command below is guaranteed not to start until this one
        // has fully settled.
        await expectLater(
          executor.execute(repoPath: '/r', gitArgs: ['git', 'status']),
          throwsA(isA<Exception>()),
        );

        // Second command: enqueue it, then bump the generation *before its
        // turn comes up* — simulating a reconnect/disconnect racing a
        // still-queued command. Because `execute()` chains onto the tail
        // without awaiting, and `disconnect()` has no internal `await` (its
        // whole body runs synchronously the instant it's called), the
        // generation bump below is guaranteed to happen before the queued
        // command's `_run` gets a chance to execute.
        final genAtEnqueue = manager.generation;
        final second = executor.execute(
          repoPath: '/r',
          gitArgs: ['git', 'log'],
        );
        // Deliberately not awaited: the assertion right below depends on the
        // generation bump having already happened *synchronously* (see the
        // comment above), before this test function itself next awaits
        // anything and lets the queued command's microtask run.
        unawaited(manager.disconnect());
        expect(manager.generation, isNot(genAtEnqueue));

        await expectLater(second, throwsA(isA<SSHCommandSuperseded>()));
      });

      test('a command queued while the generation is unchanged still runs '
          '(sanity check against a false positive)', () async {
        final manager = SSHClientManager();
        final executor = SSHCommandExecutor(manager);

        // No connection and no generation change — should fail with the
        // ordinary "not established" error, never SSHCommandSuperseded.
        await expectLater(
          executor.execute(repoPath: '/r', gitArgs: ['git', 'status']),
          throwsA(isNot(isA<SSHCommandSuperseded>())),
        );
      });
    },
  );

  group('splitExitTrailer recovers a compressed read\'s real exit code', () {
    test('a clean success trailer', () {
      final (code, body) = SSHCommandExecutor.splitExitTrailer(
        'diff --git a/x b/x\n+line\n\u0001EXIT=0\u0001',
      );
      expect(code, 0);
      expect(body, 'diff --git a/x b/x\n+line\n');
    });

    test('a non-zero exit survives the round trip', () {
      final (code, body) = SSHCommandExecutor.splitExitTrailer(
        '\u0001EXIT=128\u0001',
      );
      expect(code, 128);
      expect(body, isEmpty);
    });

    test('a missing trailer (killed/truncated stream) yields a null code', () {
      final (code, body) = SSHCommandExecutor.splitExitTrailer(
        'partial output...',
      );
      expect(code, isNull);
      expect(body, 'partial output...');
    });

    test('a trailer cut off mid-digits is not trusted', () {
      final (code, body) = SSHCommandExecutor.splitExitTrailer(
        'out\u0001EXIT=12',
      );
      expect(code, isNull);
      expect(body, 'out\u0001EXIT=12');
    });

    test('a stray 0x01 in the body does not false-match', () {
      final (code, body) = SSHCommandExecutor.splitExitTrailer(
        'weird\u0001bytes\u0001EXIT=0\u0001',
      );
      expect(code, 0);
      expect(body, 'weird\u0001bytes');
    });

    test('non-digit trailer content is rejected', () {
      final (code, _) = SSHCommandExecutor.splitExitTrailer(
        'out\u0001EXIT=abc\u0001',
      );
      expect(code, isNull);
    });
  });

  group('gunzipStdout', () {
    test('decodes a small payload on this isolate', () async {
      final raw = utf8.encode('hello compressed');
      final wire = Uint8List.fromList(gzip.encode(raw));
      expect(wire.length, lessThan(SSHCommandExecutor.gzipOffloadWireBytes));
      expect(await SSHCommandExecutor.gunzipStdout(wire), raw);
    });

    test('decodes a payload over the offload threshold off-isolate', () async {
      final raw = Uint8List(300 * 1024);
      final rnd = Random(1);
      for (var i = 0; i < raw.length; i++) {
        raw[i] = rnd.nextInt(256);
      }
      final wire = Uint8List.fromList(gzip.encode(raw));
      expect(wire.length, greaterThan(SSHCommandExecutor.gzipOffloadWireBytes));
      expect(await SSHCommandExecutor.gunzipStdout(wire), raw);
    });
  });

  group('isTransientTransportError / runWithRetries', () {
    test('never retries timeouts, supersession, or output cap', () {
      expect(
        SSHCommandExecutor.isTransientTransportError(
          const SSHCommandTimeout('git status'),
        ),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          const SSHCommandSuperseded('git status'),
        ),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          const SSHOutputExceeded('git log'),
        ),
        isFalse,
      );
    });

    test('never retries deterministic client errors', () {
      expect(
        SSHCommandExecutor.isTransientTransportError(ArgumentError('bad path')),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          const FormatException('bad gzip'),
        ),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          StateError('no active SSH connection'),
        ),
        isFalse,
      );
    });

    test('retries connection-closed style transport blips', () {
      expect(
        SSHCommandExecutor.isTransientTransportError(
          Exception('SSH connection closed by peer'),
        ),
        isTrue,
      );
    });

    test(
      'never retries peer disconnect, handshake timeout, or malformed packet',
      () {
        expect(
          SSHCommandExecutor.isTransientTransportError(
            SSHDisconnectError(3, 'no matching key exchange method found'),
          ),
          isFalse,
        );
        expect(
          SSHCommandExecutor.isTransientTransportError(
            SSHHandshakeError('Handshake timed out'),
          ),
          isFalse,
        );
        expect(
          SSHCommandExecutor.isTransientTransportError(
            SSHPacketError('truncated'),
          ),
          isFalse,
        );
      },
    );

    test('runWithRetries does not re-issue a FormatException', () async {
      var calls = 0;
      await expectLater(
        SSHCommandExecutor.runWithRetries(() async {
          calls++;
          throw const FormatException('corrupt');
        }, 3),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 1);
    });

    test('runWithRetries re-issues a transient transport error once', () async {
      var calls = 0;
      final result = await SSHCommandExecutor.runWithRetries(
        () async {
          calls++;
          if (calls == 1) {
            throw Exception('connection closed unexpectedly');
          }
          return const SSHCommandResult(exitCode: 0, stdout: 'ok', stderr: '');
        },
        1,
        backoff: Duration.zero,
      );
      expect(calls, 2);
      expect(result.stdout, 'ok');
    });

    test('SSHChannelOpenError is transient and counts telemetry', () async {
      CommandTelemetry.instance.reset();
      expect(
        SSHCommandExecutor.isTransientTransportError(
          SSHChannelOpenError(2, 'Administratively prohibited'),
        ),
        isTrue,
      );

      var calls = 0;
      await expectLater(
        SSHCommandExecutor.runWithRetries(
          () async {
            calls++;
            throw SSHChannelOpenError(2, 'Administratively prohibited');
          },
          1,
          backoff: Duration.zero,
        ),
        throwsA(isA<SSHChannelOpenError>()),
      );
      // Initial + one retry; each failure records a channel-open error.
      expect(calls, 2);
      expect(CommandTelemetry.instance.channelOpenErrors, 2);
    });

    test('channel-open error is recorded even when retries are zero', () async {
      CommandTelemetry.instance.reset();
      await expectLater(
        SSHCommandExecutor.runWithRetries(
          () async => throw SSHChannelOpenError(1, 'full'),
          0,
        ),
        throwsA(isA<SSHChannelOpenError>()),
      );
      expect(CommandTelemetry.instance.channelOpenErrors, 1);
    });
  });
}
