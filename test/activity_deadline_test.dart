import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/activity_deadline.dart';

void main() {
  test('pulse every 10 ms with idle 50 ms and ceiling 1 s completes', () async {
    final deadline = ActivityDeadline(
      idle: const Duration(milliseconds: 50),
      ceiling: const Duration(seconds: 1),
    );
    final inner = Completer<int>();
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      deadline.pulse();
    });
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!inner.isCompleted) inner.complete(7);
    });
    try {
      expect(await deadline.wait(inner.future), 7);
    } finally {
      ticker.cancel();
    }
  });

  test('no pulse, idle 50 ms throws TimeoutException', () async {
    final deadline = ActivityDeadline(
      idle: const Duration(milliseconds: 50),
      ceiling: const Duration(seconds: 1),
    );
    await expectLater(
      deadline.wait(Completer<void>().future),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('pulse forever, ceiling 50 ms throws TimeoutException', () async {
    final deadline = ActivityDeadline(
      idle: const Duration(seconds: 5),
      ceiling: const Duration(milliseconds: 50),
    );
    final ticker = Timer.periodic(const Duration(milliseconds: 5), (_) {
      deadline.pulse();
    });
    try {
      await expectLater(
        deadline.wait(Completer<void>().future),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      ticker.cancel();
    }
  });
}
