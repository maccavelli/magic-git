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
}
