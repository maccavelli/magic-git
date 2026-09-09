// MADR 0039 F6/H2. A watcher tick suppressed as "probably our own echo" is
// deferred, never dropped: at most one extra refresh per window, and no
// external change can be lost — only delayed, by at most maxDeferral.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/suppressed_tick.dart';

void main() {
  test('one hold flushes exactly once, after the window', () {
    fakeAsync((async) {
      var flushes = 0;
      final tick = SuppressedTick(
        onFlush: () => flushes++,
        stillSuppressed: () => false,
        window: const Duration(seconds: 3),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      tick.hold();
      expect(tick.isHolding, isTrue);

      async.elapse(const Duration(milliseconds: 2999));
      expect(flushes, 0, reason: 'not before the echo window is over');

      async.elapse(const Duration(milliseconds: 2));
      expect(flushes, 1);
      expect(tick.isHolding, isFalse);

      async.elapse(const Duration(minutes: 5));
      expect(flushes, 1, reason: 'the flush is one-shot, not periodic');
    });
  });

  test('a burst of holds inside one window coalesces to one flush', () {
    fakeAsync((async) {
      var flushes = 0;
      final tick = SuppressedTick(
        onFlush: () => flushes++,
        stillSuppressed: () => false,
        window: const Duration(seconds: 3),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      for (var i = 0; i < 5; i++) {
        tick.hold();
        async.elapse(const Duration(milliseconds: 200));
      }
      expect(flushes, 0);

      async.elapse(const Duration(seconds: 3));
      expect(
        flushes,
        1,
        reason:
            'the deferral costs at most one refresh per window — the same '
            'order as what the suppression saves',
      );
    });
  });

  test('a still-suppressed tick re-holds rather than flushing early', () {
    fakeAsync((async) {
      var flushes = 0;
      var suppressed = true;
      final tick = SuppressedTick(
        onFlush: () => flushes++,
        stillSuppressed: () => suppressed,
        window: const Duration(seconds: 3),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      tick.hold();
      async.elapse(const Duration(seconds: 3));
      expect(flushes, 0, reason: 'our own operation is still in flight');

      suppressed = false;
      async.elapse(const Duration(seconds: 3));
      expect(flushes, 1, reason: 'flushed on the first re-check that clears');
    });
  });

  test('maxDeferral flushes even while still suppressed', () {
    // The bound. `isRecent` is true for the WHOLE of an in-flight fetch, and a
    // background fetch can run for minutes — without this, an external change
    // arriving during one is hidden for that entire time.
    fakeAsync((async) {
      var flushes = 0;
      final tick = SuppressedTick(
        onFlush: () => flushes++,
        stillSuppressed: () => true, // a long fetch that never settles
        window: const Duration(seconds: 3),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      tick.hold();
      async.elapse(const Duration(seconds: 8));
      expect(flushes, 0, reason: 'still inside the 9 s default bound');

      async.elapse(const Duration(seconds: 2));
      expect(flushes, 1, reason: 'past maxDeferral it flushes regardless');
      expect(tick.isHolding, isFalse);

      async.elapse(const Duration(minutes: 5));
      expect(flushes, 1, reason: 'and does not then flush repeatedly');
    });
  });

  test('holds during an unending operation cannot defer forever', () {
    // `hold()` deliberately does not re-arm. A steady stream of suppressed
    // ticks — a build writing files while a fetch runs — must not keep pushing
    // the flush out.
    fakeAsync((async) {
      var flushes = 0;
      final tick = SuppressedTick(
        onFlush: () => flushes++,
        stillSuppressed: () => true,
        window: const Duration(seconds: 3),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      for (var i = 0; i < 60; i++) {
        tick.hold();
        async.elapse(const Duration(milliseconds: 500));
      }

      expect(
        flushes,
        greaterThanOrEqualTo(1),
        reason: 'a continuous event stream must still surface within the bound',
      );
    });
  });

  test('cancel drops a held tick without flushing', () {
    fakeAsync((async) {
      var flushes = 0;
      final tick = SuppressedTick(
        onFlush: () => flushes++,
        stillSuppressed: () => false,
        window: const Duration(seconds: 3),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      tick.hold();
      tick.cancel();
      expect(tick.isHolding, isFalse);

      async.elapse(const Duration(minutes: 1));
      expect(flushes, 0, reason: 'a disposed View must not be called back');
    });
  });
}
