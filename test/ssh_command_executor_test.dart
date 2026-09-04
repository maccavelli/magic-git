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

import 'helpers/fake_ssh_client.dart';

void main() {
  group('SSHClientManager generation + client slots', () {
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

    test('a sustained queueing sequence lowers the cap', () {
      final executor = SSHCommandExecutor(SSHClientManager());
      // Unqueued reads first: the controller has to have a best-case to
      // measure against before "queueing" means anything.
      for (var i = 0; i < 12; i++) {
        executor.noteReadSample(const Duration(milliseconds: 40));
      }
      expect(executor.adaptiveReadCap, 4);

      for (var i = 0; i < 6; i++) {
        executor.noteReadSample(const Duration(seconds: 4));
      }
      expect(executor.adaptiveReadCap, 2);
    });

    test('resetAdaptiveReads and resetEnvironment restore no-sample cap', () {
      final executor = SSHCommandExecutor(SSHClientManager());
      for (var i = 0; i < 12; i++) {
        executor.noteReadSample(const Duration(milliseconds: 40));
      }
      for (var i = 0; i < 6; i++) {
        executor.noteReadSample(const Duration(seconds: 4));
      }
      expect(executor.adaptiveReadCap, 2);

      executor.resetAdaptiveReads();
      expect(executor.adaptiveReadCap, 3);

      for (var i = 0; i < 13; i++) {
        executor.noteReadSample(const Duration(milliseconds: 40));
      }
      expect(executor.adaptiveReadCap, 4);
      executor.resetEnvironment();
      expect(executor.adaptiveReadCap, 3);
    });

    test(
      'an unqueued sequence raises the cap to the production ceiling of 4',
      () {
        final executor = SSHCommandExecutor(SSHClientManager());
        // Deliberately slow, and deliberately steady: 250 ms with no queueing is
        // a satellite link that is perfectly happy at the full ceiling. The RTT
        // band table this replaced pinned exactly this case to 2 (0024 M1).
        for (var i = 0; i < 13; i++) {
          executor.noteReadSample(const Duration(milliseconds: 250));
        }
        expect(executor.adaptiveReadCap, 4);
      },
    );
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

    // 0024 H2. Charging the budget AFTER a full decode bounds what gets
    // reported, not what gets allocated — by then the allocation the budget
    // exists to prevent has already happened. gzip's maximum ratio is ~1032:1.
    test('a gzip bomb is refused during decompression, not after it', () async {
      final raw = Uint8List(8 * 1024 * 1024); // zeroes: compresses ~1000x
      final wire = Uint8List.fromList(gzip.encode(raw));
      expect(
        wire.length,
        lessThan(64 * 1024),
        reason: 'sanity: the fixture has to actually be a bomb',
      );

      await expectLater(
        SSHCommandExecutor.gunzipStdout(wire, limit: 1024, label: 'bomb'),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('a bomb over the offload threshold is refused too', () async {
      // The off-isolate path is where the allocation actually hurts, and it
      // returns its refusal across the isolate boundary rather than throwing.
      //
      // Zeroes alone cannot build this fixture: they compress ~1000:1, so a
      // payload big enough to blow the decompressed cap still lands well under
      // the wire threshold that selects the isolate. An incompressible prefix
      // sets the wire size; the zero run supplies the expansion.
      final rnd = Random(7);
      final prefix = Uint8List(300 * 1024);
      for (var i = 0; i < prefix.length; i++) {
        prefix[i] = rnd.nextInt(256);
      }
      final raw = Uint8List.fromList([
        ...prefix,
        ...Uint8List(8 * 1024 * 1024),
      ]);
      final wire = Uint8List.fromList(gzip.encode(raw));
      expect(wire.length, greaterThan(SSHCommandExecutor.gzipOffloadWireBytes));

      await expectLater(
        SSHCommandExecutor.gunzipStdout(wire, limit: 4096, label: 'bomb'),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('a payload inside the limit still decodes whole', () async {
      final raw = Uint8List.fromList(utf8.encode('hello ' * 1000));
      final wire = Uint8List.fromList(gzip.encode(raw));
      expect(await SSHCommandExecutor.gunzipStdout(wire, limit: 1 << 20), raw);
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

  group('bindTestClients test seam', () {
    test('makes execute see an established connection', () async {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      final client = FakeSshClient();
      manager.bindTestClients(command: client);

      final result = await executor.execute(repoPath: '/r', gitArgs: ['true']);

      expect(result.isSuccess, isTrue);
      expect(result.exitCode, 0);
      expect(client.executeCommands, hasLength(1));
      expect(client.executeCommands.single, contains('true'));
      expect(manager.attachedClientCount, 1);
      expect(manager.clientGeneration, manager.generation);
    });

    test('binding no command client leaves the connection unestablished', () {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      manager.bindTestClients();

      expect(manager.attachedClientCount, 0);
      expect(manager.clientGeneration, -1);
      expect(
        executor.execute(repoPath: '/r', gitArgs: ['true']),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('ExecLane routing across the client slots', () {
    // `executeCommands` holds formatted shell strings (`cd '<repo>' && …`),
    // not argv — so match on a marker substring, never list membership.
    bool ran(FakeSshClient client, String marker) =>
        client.executeCommands.any((cmd) => cmd.contains(marker));

    test('sync uses syncClient; other lanes use the command client', () async {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      final command = FakeSshClient();
      final sync = FakeSshClient();
      manager.bindTestClients(command: command, sync: sync);

      await executor.execute(
        repoPath: '/r',
        gitArgs: ['zz-read'],
        lane: ExecLane.read,
      );
      await executor.execute(
        repoPath: '/r',
        gitArgs: ['zz-sync'],
        lane: ExecLane.sync,
      );
      await executor.execute(
        repoPath: '/r',
        gitArgs: ['zz-mut'],
        lane: ExecLane.exclusive,
      );

      expect(ran(command, 'zz-read'), isTrue);
      expect(ran(command, 'zz-mut'), isTrue);
      expect(ran(command, 'zz-sync'), isFalse);

      expect(ran(sync, 'zz-sync'), isTrue);
      expect(ran(sync, 'zz-read'), isFalse);
      expect(ran(sync, 'zz-mut'), isFalse);
    });

    test('a degraded sync lane shares the command client', () async {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      final command = FakeSshClient();
      final stream = FakeSshClient();
      manager.bindTestClients(command: command, stream: stream);

      expect(manager.syncClientDegraded, isTrue);
      expect(manager.attachedClientCount, 2);
      // The fallback must be the *command* client, not a null slot.
      expect(identical(manager.syncClient, command), isTrue);

      await executor.execute(
        repoPath: '/r',
        gitArgs: ['zz-sync'],
        lane: ExecLane.sync,
      );

      expect(ran(command, 'zz-sync'), isTrue);
      expect(ran(stream, 'zz-sync'), isFalse);
    });

    test('attachedClientCount counts the bound slots', () {
      final manager = SSHClientManager();
      expect(manager.attachedClientCount, 0);

      manager.bindTestClients(
        command: FakeSshClient(),
        stream: FakeSshClient(),
        sync: FakeSshClient(),
      );
      expect(manager.attachedClientCount, 3);
      expect(manager.syncClientDegraded, isFalse);
      expect(manager.streamClientDegraded, isFalse);

      manager.bindTestClients(command: FakeSshClient());
      expect(manager.attachedClientCount, 1);
      expect(manager.syncClientDegraded, isTrue);
      expect(manager.streamClientDegraded, isTrue);
    });
  });

  group('uploadBytes sideloads stdin', () {
    test('feeds stdin via addStream, flush, then close', () async {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      // uploadBytes runs on ExecLane.isolated — the command client, not sync —
      // and throws unless the result is exit 0.
      final client = FakeSshClient();
      manager.bindTestClients(command: client);

      await executor.uploadBytes('/tmp/x y', Uint8List.fromList([1, 2, 3]));

      final session = client.sessions.single;
      // A regression to `session.write(stdin)` records 'write' here; a
      // regression to a single buffered `stdin.add` records 'add'. Either
      // fails, which is the point of 0014 T7.
      expect(session.stdinOps, ['addStream', 'flush', 'close']);
      expect(session.stdinBytes, Uint8List.fromList([1, 2, 3]));

      expect(client.executeCommands.single, contains('cat >'));
      expect(client.executeCommands.single, contains(r"'/tmp/x y'"));
    });
  });

  group('activityIdle through SSHCommandExecutor.execute', () {
    late SSHClientManager manager;
    late SSHCommandExecutor executor;
    late FakeSshClient client;
    late StreamController<Uint8List> out;
    late StreamController<Uint8List> err;
    late Completer<int?> exit;
    Timer? pulser;

    setUp(() {
      manager = SSHClientManager();
      executor = SSHCommandExecutor(manager);
      client = FakeSshClient();
      out = StreamController<Uint8List>();
      err = StreamController<Uint8List>();
      exit = Completer<int?>();
      client
        ..nextStdout = out
        ..nextStderr = err
        ..nextExit = exit;
      manager.bindTestClients(command: client);
    });

    tearDown(() async {
      pulser?.cancel();
      pulser = null;
      if (!exit.isCompleted) exit.complete(0);
      await out.close();
      await err.close();
    });

    /// Emits a byte every [every] until [ticks] have fired, then closes both
    /// streams and exits 0. `period > idle budget` is the point: only the
    /// `deadline.pulse()` calls in the drain keep the command alive.
    void pulseThenFinish(
      StreamController<Uint8List> target, {
      required Duration every,
      required int ticks,
    }) {
      var fired = 0;
      pulser = Timer.periodic(every, (t) async {
        if (fired++ >= ticks) {
          t.cancel();
          pulser = null;
          await out.close();
          await err.close();
          if (!exit.isCompleted) exit.complete(0);
          return;
        }
        target.add(Uint8List.fromList([0x70]));
      });
    }

    test('a session pulsing stderr past the idle budget completes', () async {
      pulseThenFinish(err, every: const Duration(milliseconds: 40), ticks: 8);

      final result = await executor.execute(
        repoPath: '/r',
        gitArgs: ['git', 'fetch'],
        activityIdle: const Duration(milliseconds: 120),
        timeout: const Duration(seconds: 5),
      );

      expect(result.isSuccess, isTrue);
      expect(result.stderr, isNotEmpty);
    });

    test('a session pulsing stdout past the idle budget completes', () async {
      pulseThenFinish(out, every: const Duration(milliseconds: 40), ticks: 8);

      final result = await executor.execute(
        repoPath: '/r',
        gitArgs: ['git', 'fetch'],
        activityIdle: const Duration(milliseconds: 120),
        timeout: const Duration(seconds: 5),
      );

      expect(result.isSuccess, isTrue);
      expect(result.stdout, isNotEmpty);
    });

    test('a silent session throws SSHCommandTimeout', () async {
      await expectLater(
        executor.execute(
          repoPath: '/r',
          gitArgs: ['git', 'fetch'],
          activityIdle: const Duration(milliseconds: 80),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<SSHCommandTimeout>()),
      );
    });

    test('the ceiling still kills a pulsing session', () async {
      // Never finishes: ticks far beyond what the ceiling allows.
      pulseThenFinish(
        out,
        every: const Duration(milliseconds: 20),
        ticks: 1000,
      );

      await expectLater(
        executor.execute(
          repoPath: '/r',
          gitArgs: ['git', 'fetch'],
          activityIdle: const Duration(seconds: 5),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<SSHCommandTimeout>()),
      );
    });
  });

  group('stream channel budget', () {
    test(
      'refuses the channel the host would refuse, and frees it again',
      () async {
        final manager = SSHClientManager();
        final executor = SSHCommandExecutor(manager);
        final streamClient = FakeSshClient();
        manager.bindTestClients(command: FakeSshClient(), stream: streamClient);
        expect(executor.maxConcurrentStreams, 8, reason: 'not degraded');

        // A FakeSshSession completes its exit immediately unless the test hands
        // it a pending one, and a completed exit closes the handle — which would
        // free every slot as fast as it was taken. A watcher stays open.
        Future<SSHStreamHandle> open() {
          streamClient.nextExit = Completer<int?>();
          return executor.executeStream(repoPath: '/r', gitArgs: const ['w']);
        }

        final handles = <SSHStreamHandle>[];
        for (var i = 0; i < executor.maxConcurrentStreams; i++) {
          handles.add(await open());
        }
        expect(executor.activeStreams, 8);

        await expectLater(open(), throwsA(isA<SSHStreamBudgetExhausted>()));

        // Closing one gives the slot back — the budget is a live count, not a
        // one-way latch.
        await handles.removeLast().cancel();
        expect(executor.activeStreams, 7);
        handles.add(await open());
        expect(executor.activeStreams, 8);
        for (final h in handles) {
          await h.cancel();
        }
      },
    );

    test('a degraded stream client gets the smaller budget', () {
      final manager = SSHClientManager();
      final executor = SSHCommandExecutor(manager);
      // No stream client: streams land on the command connection, which is
      // already carrying reads, isolated work and possibly the sync lane.
      manager.bindTestClients(command: FakeSshClient());
      expect(manager.streamClientDegraded, isTrue);
      expect(executor.maxConcurrentStreams, 2);
    });

    test('budget exhaustion is never retried', () {
      // Deterministic, unlike a host refusal: retrying just reproduces it.
      expect(
        SSHCommandExecutor.isTransientTransportError(
          const SSHStreamBudgetExhausted('w', 8, 8),
        ),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          SSHChannelOpenError(1, 'busy'),
        ),
        isTrue,
        reason: 'a host refusal remains a transient blip',
      );
    });
  });
}
