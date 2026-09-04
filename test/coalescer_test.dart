import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/coalescer.dart';

void main() {
  group('Coalescer', () {
    test('collapses a burst into a single trailing fire', () {
      fakeAsync((async) {
        final base = DateTime(2020);
        var fires = 0;
        final c = Coalescer(
          trailing: const Duration(milliseconds: 150),
          maxWait: const Duration(seconds: 1),
          minInterval: const Duration(seconds: 1),
          onFire: () => fires++,
          now: () => base.add(async.elapsed),
        );

        // Five rapid events within the trailing window.
        for (var i = 0; i < 5; i++) {
          c.signal();
          async.elapse(const Duration(milliseconds: 20));
        }
        expect(fires, 0); // still settling

        async.elapse(const Duration(milliseconds: 150));
        expect(fires, 1); // one fire for the whole burst
      });
    });

    test('maxWait ceiling fires a continuous writer that never settles', () {
      fakeAsync((async) {
        final base = DateTime(2020);
        var fires = 0;
        final c = Coalescer(
          trailing: const Duration(milliseconds: 150),
          maxWait: const Duration(seconds: 1),
          minInterval: Duration.zero,
          onFire: () => fires++,
          now: () => base.add(async.elapsed),
        );

        // Signal every 100ms for 2s — the trailing timer keeps resetting, but
        // the maxWait ceiling must still force a fire within ~1s.
        for (var i = 0; i < 20; i++) {
          c.signal();
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(fires, greaterThanOrEqualTo(1));
      });
    });

    test('minInterval prevents fires closer than the floor', () {
      fakeAsync((async) {
        final base = DateTime(2020);
        final fireTimes = <Duration>[];
        final c = Coalescer(
          trailing: const Duration(milliseconds: 50),
          maxWait: const Duration(milliseconds: 100),
          minInterval: const Duration(seconds: 2),
          onFire: () => fireTimes.add(async.elapsed),
          now: () => base.add(async.elapsed),
        );

        c.signal();
        async.elapse(const Duration(milliseconds: 60));
        expect(fireTimes, hasLength(1));

        // A second burst immediately after must wait out the 2s minInterval.
        c.signal();
        async.elapse(const Duration(milliseconds: 200));
        expect(fireTimes, hasLength(1)); // still gated

        async.elapse(const Duration(seconds: 2));
        expect(fireTimes, hasLength(2));
        expect(
          fireTimes[1] - fireTimes[0],
          greaterThanOrEqualTo(const Duration(seconds: 2)),
        );
      });
    });

    test('cancel stops a pending fire', () {
      fakeAsync((async) {
        var fires = 0;
        final c = Coalescer(
          trailing: const Duration(milliseconds: 150),
          maxWait: const Duration(seconds: 1),
          minInterval: Duration.zero,
          onFire: () => fires++,
        );
        c.signal();
        c.cancel();
        async.elapse(const Duration(seconds: 5));
        expect(fires, 0);
      });
    });
  });

  group('reschedule cost', () {
    test('a tight burst does not rebuild the timer per event', () {
      // 0024 A1.1. The trailing debounce's target moves by microseconds inside
      // a burst, yet the timer was destroyed and rebuilt on every event:
      // measured 295 ms of the 333 ms a 20,000-event `git checkout` burst cost
      // on the UI isolate, against 9 ms once the reschedule is guarded.
      var fires = 0;
      final c = Coalescer(
        trailing: const Duration(milliseconds: 150),
        maxWait: const Duration(seconds: 1),
        minInterval: const Duration(seconds: 1),
        onFire: () => fires++,
      );
      addTearDown(c.cancel);

      const n = 20000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        c.signal();
      }
      sw.stop();

      // ~30x under the measured churn, ~5x over the guarded cost, so it can
      // neither flake on a slow machine nor pass on the unguarded version.
      expect(
        sw.elapsedMilliseconds,
        lessThan(50),
        reason: 'signal() must not cancel and rebuild a Timer per event',
      );
      expect(fires, 0, reason: 'nothing should have fired synchronously');
    });

    test('a guarded reschedule still fires, and never late', () {
      fakeAsync((async) {
        final base = DateTime(2026);
        final fireTimes = <Duration>[];
        final c = Coalescer(
          trailing: const Duration(milliseconds: 150),
          maxWait: const Duration(milliseconds: 500),
          minInterval: Duration.zero,
          onFire: () => fireTimes.add(async.elapsed),
          now: () => base.add(async.elapsed),
        );

        // A continuous writer: the maxWait ceiling must still land on time,
        // which is what forbids the guard from ever deferring a fire.
        for (var i = 0; i < 40; i++) {
          c.signal();
          async.elapse(const Duration(milliseconds: 20));
        }

        expect(fireTimes, isNotEmpty);
        expect(
          fireTimes.first.inMilliseconds,
          lessThanOrEqualTo(500),
          reason: 'the maxWait ceiling must not slip',
        );
        c.cancel();
      });
    });
  });
}
