// Regression coverage for SSHCommandExecutor's connection-generation pinning
// (a command queued before a reconnect/disconnect must refuse to run against
// whatever connection happens to be current by the time its turn comes up,
// not silently execute against it) and SSHClientManager's generation
// bookkeeping, which the pinning depends on. Uses a real (unfaked)
// SSHClientManager throughout — no live socket is needed for these cases
// since the assertions never depend on a client actually being connected.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  group('SSHClientManager generation', () {
    test('starts at 0 and is bumped by disconnect even with no connection', () {
      final manager = SSHClientManager();
      expect(manager.generation, 0);
      manager.disconnect();
      expect(manager.generation, 1);
      manager.disconnect();
      expect(manager.generation, 2);
    });
  });

  group('SSHCommandExecutor pins each command to its enqueue-time generation', () {
    test(
      'a command already queued when a disconnect happens is refused, '
      'not silently run against the new state',
      () async {
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
        final second = executor.execute(repoPath: '/r', gitArgs: ['git', 'log']);
        // Deliberately not awaited: the assertion right below depends on the
        // generation bump having already happened *synchronously* (see the
        // comment above), before this test function itself next awaits
        // anything and lets the queued command's microtask run.
        unawaited(manager.disconnect());
        expect(manager.generation, isNot(genAtEnqueue));

        await expectLater(second, throwsA(isA<SSHCommandSuperseded>()));
      },
    );

    test(
      'a command queued while the generation is unchanged still runs '
      '(sanity check against a false positive)',
      () async {
        final manager = SSHClientManager();
        final executor = SSHCommandExecutor(manager);

        // No connection and no generation change — should fail with the
        // ordinary "not established" error, never SSHCommandSuperseded.
        await expectLater(
          executor.execute(repoPath: '/r', gitArgs: ['git', 'status']),
          throwsA(isNot(isA<SSHCommandSuperseded>())),
        );
      },
    );
  });

  group('SSHCommandExecutor.collectBounded bounds a command\'s output', () {
    test('normal-sized output is accumulated unchanged', () async {
      final out = await SSHCommandExecutor.collectBounded(
        Stream.fromIterable(['abc', 'de', 'f']),
        'git status',
        maxChars: 1024,
      );
      expect(out, 'abcdef');
    });

    test('output past the ceiling aborts with SSHOutputExceeded', () async {
      // 8 chars arrive against a 5-char ceiling — must fail, not buffer it all.
      await expectLater(
        SSHCommandExecutor.collectBounded(
          Stream.fromIterable(['aaaa', 'bbbb']),
          'git log',
          maxChars: 5,
        ),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('output exactly at the ceiling is allowed', () async {
      final out = await SSHCommandExecutor.collectBounded(
        Stream.fromIterable(['aaaaa']),
        'git log',
        maxChars: 5,
      );
      expect(out, 'aaaaa');
    });
  });

  group('splitExitTrailer recovers a compressed read\'s real exit code', () {
    test('a clean success trailer', () {
      final (code, body) = SSHCommandExecutor.splitExitTrailer(
        'diff --git a/x b/x\n+line\n\u0001EXIT=0\u0001',
      );
      expect(code, 0);
      expect(body, 'diff --git a/x b/x\n+line\n');
    });

    test('a non-zero exit survives the round trip', () {
      final (code, body) =
          SSHCommandExecutor.splitExitTrailer('\u0001EXIT=128\u0001');
      expect(code, 128);
      expect(body, isEmpty);
    });

    test('a missing trailer (killed/truncated stream) yields a null code', () {
      final (code, body) =
          SSHCommandExecutor.splitExitTrailer('partial output...');
      expect(code, isNull);
      expect(body, 'partial output...');
    });

    test('a trailer cut off mid-digits is not trusted', () {
      final (code, body) =
          SSHCommandExecutor.splitExitTrailer('out\u0001EXIT=12');
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
      final (code, _) =
          SSHCommandExecutor.splitExitTrailer('out\u0001EXIT=abc\u0001');
      expect(code, isNull);
    });
  });

  group('OutputByteBudget / boundedBytes bound on raw bytes', () {
    List<int> bytes(int n) => List<int>.filled(n, 0x61);

    test('passes chunks through unchanged while under budget', () async {
      final budget = OutputByteBudget(1024);
      final out = await SSHCommandExecutor.boundedBytes(
        Stream.fromIterable([bytes(3), bytes(2)]),
        budget,
        'git status',
      ).toList();
      expect(out.map((c) => c.length).toList(), [3, 2]);
      expect(budget.used, 5);
    });

    test('aborts with SSHOutputExceeded once the byte budget is crossed',
        () async {
      final budget = OutputByteBudget(5);
      await expectLater(
        SSHCommandExecutor.boundedBytes(
          Stream.fromIterable([bytes(4), bytes(4)]),
          budget,
          'git log',
        ).toList(),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('a single shared budget bounds stdout + stderr *combined*', () async {
      // 4 + 3 = 7 bytes across two streams sharing a 6-byte budget → the
      // combined total trips it, even though neither stream alone would.
      final budget = OutputByteBudget(6);
      final out = SSHCommandExecutor.boundedBytes(
        Stream.fromIterable([bytes(4)]),
        budget,
        'cmd',
      ).toList();
      final err = SSHCommandExecutor.boundedBytes(
        Stream.fromIterable([bytes(3)]),
        budget,
        'cmd',
      ).toList();
      await expectLater(
        Future.wait([out, err], eagerError: true),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('counts bytes, not decoded code units (multi-byte UTF-8)', () async {
      // "é" is 2 UTF-8 bytes but 1 code unit; a byte budget must charge 2.
      final budget = OutputByteBudget(1);
      await expectLater(
        SSHCommandExecutor.boundedBytes(
          Stream.fromIterable([
            [0xC3, 0xA9], // 'é' in UTF-8
          ]),
          budget,
          'cmd',
        ).toList(),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });
  });
}
