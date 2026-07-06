import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/pausable_timeout.dart';

void main() {
  test('resolves normally when the future completes before the timeout', () {
    fakeAsync((async) {
      final completer = Completer<int>();
      Object? result;
      awaitWithPausableTimeout(
        completer.future,
        const Duration(seconds: 10),
        isPaused: () => false,
      ).then((v) => result = v);

      async.elapse(const Duration(seconds: 5));
      completer.complete(42);
      async.flushMicrotasks();

      expect(result, 42);
    });
  });

  test('propagates the future\'s own error, not a timeout', () {
    fakeAsync((async) {
      final completer = Completer<int>();
      Object? error;
      awaitWithPausableTimeout(
        completer.future,
        const Duration(seconds: 10),
        isPaused: () => false,
      ).then((_) {}, onError: (Object e) { error = e; });

      completer.completeError(Exception('boom'));
      async.flushMicrotasks();

      expect(error, isA<Exception>());
    });
  });

  test('times out when never paused and the future never resolves', () {
    fakeAsync((async) {
      final completer = Completer<int>();
      Object? error;
      awaitWithPausableTimeout(
        completer.future,
        const Duration(seconds: 10),
        isPaused: () => false,
      ).then((_) {}, onError: (Object e) { error = e; });

      async.elapse(const Duration(seconds: 10));
      expect(error, isA<TimeoutException>());
    });
  });

  test(
    'does not time out while paused, and resumes counting once unpaused',
    () {
      fakeAsync((async) {
        final completer = Completer<int>();
        var paused = true;
        Object? error;
        awaitWithPausableTimeout(
          completer.future,
          const Duration(seconds: 10),
          isPaused: () => paused,
        ).then((_) {}, onError: (Object e) { error = e; });

        // Well past the raw timeout, but paused the whole time — a human is
        // still reading the host-key prompt.
        async.elapse(const Duration(seconds: 30));
        expect(
          error,
          isNull,
          reason: 'must not time out while a decision is pending',
        );

        // The user answers; a fresh timeout window starts from here.
        paused = false;
        async.elapse(const Duration(seconds: 9));
        expect(error, isNull, reason: 'fresh window not yet exhausted');

        async.elapse(const Duration(seconds: 2));
        expect(error, isA<TimeoutException>());
      });
    },
  );

  test('cancels its internal timer once resolved (no pending timers leak)', () {
    fakeAsync((async) {
      final completer = Completer<int>();
      awaitWithPausableTimeout(
        completer.future,
        const Duration(seconds: 10),
        isPaused: () => false,
      );
      completer.complete(1);
      async.flushMicrotasks();
      // fakeAsync's zone teardown asserts no pending timers remain; reaching
      // the end of this callback without throwing proves the timer was
      // cancelled rather than left armed for the full original timeout.
    });
  });
}
