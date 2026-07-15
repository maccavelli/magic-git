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
  });

  test('SSHOutputExceeded message includes command', () {
    const e = SSHOutputExceeded('git log');
    expect(e.toString(), contains('git log'));
  });
}
