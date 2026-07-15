// command_drain.dart: shared bounded drain helpers used by SSH + local executors.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_drain.dart';

void main() {
  group('collectBounded', () {
    test('concatenates under the cap', () async {
      final out = await collectBounded(
        Stream.fromIterable(['a', 'b', 'c']),
        'cmd',
        maxChars: 10,
      );
      expect(out, 'abc');
    });

    test('throws SSHOutputExceeded past maxChars', () async {
      await expectLater(
        collectBounded(
          Stream.fromIterable(['12345', '6']),
          'cmd',
          maxChars: 5,
        ),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('output exactly at the ceiling is allowed', () async {
      final out = await collectBounded(
        Stream.fromIterable(['aaaaa']),
        'git log',
        maxChars: 5,
      );
      expect(out, 'aaaaa');
    });
  });

  group('OutputByteBudget', () {
    test('charge accumulates and throws over limit', () {
      final budget = OutputByteBudget(5);
      budget.charge(3, 'c');
      expect(budget.used, 3);
      expect(() => budget.charge(3, 'c'), throwsA(isA<SSHOutputExceeded>()));
    });

    test('default limit matches maxCommandOutputBytes', () {
      final budget = OutputByteBudget();
      expect(budget.limit, maxCommandOutputBytes);
    });
  });

  group('boundedBytes', () {
    List<int> bytes(int n) => List<int>.filled(n, 0x61);

    test('yields chunks while under budget', () async {
      final budget = OutputByteBudget(10);
      final out = await boundedBytes(
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
        budget,
        'cmd',
      ).toList();
      expect(out, [
        [1, 2],
        [3],
      ]);
      expect(budget.used, 3);
    });

    test('aborts with SSHOutputExceeded once the byte budget is crossed',
        () async {
      final budget = OutputByteBudget(5);
      await expectLater(
        boundedBytes(
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
      final out = boundedBytes(
        Stream.fromIterable([bytes(4)]),
        budget,
        'cmd',
      ).toList();
      final err = boundedBytes(
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
        boundedBytes(
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

  test('SSHOutputExceeded message includes command', () {
    const e = SSHOutputExceeded('git log');
    expect(e.toString(), contains('git log'));
  });
}
