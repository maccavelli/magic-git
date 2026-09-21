import 'dart:async';

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
      //
      // The property is counted, not timed: every Timer the coalescer builds
      // goes through the zone's createTimer hook, and the burst runs on fake
      // time, so the count depends only on the events' timestamps. A
      // Stopwatch budget here measured the machine's load as much as the
      // coalescer, and failed under a busy full-suite run.
      fakeAsync((async) {
        final base = DateTime(2026);
        const trailing = Duration(milliseconds: 150);
        const n = 20000;
        const step = Duration(microseconds: 1);
        var timersBuilt = 0;
        final fireTimes = <Duration>[];

        runZoned(
          () {
            final c = Coalescer(
              trailing: trailing,
              maxWait: const Duration(seconds: 1),
              minInterval: const Duration(seconds: 1),
              onFire: () => fireTimes.add(async.elapsed),
              now: () => base.add(async.elapsed),
            );
            addTearDown(c.cancel);

            // 20,000 events one microsecond apart: a 20 ms burst.
            for (var i = 0; i < n; i++) {
              c.signal();
              if (i < n - 1) async.elapse(step);
            }
            final lastEvent = async.elapsed;

            // Each event pushes the trailing target one step later. The timer
            // is rebuilt only once the target has moved more than the
            // tolerance past the scheduled one: at the first event, then
            // every (tolerance + step) of burst.
            final perRebuild = Coalescer.rescheduleTolerance + step;
            final expected =
                lastEvent.inMicroseconds ~/ perRebuild.inMicroseconds + 1;
            expect(expected, 3, reason: 'sanity: a 20 ms burst, 8 ms guard');
            expect(
              timersBuilt,
              expected,
              reason: 'signal() must not cancel and rebuild a Timer per event',
            );
            expect(fireTimes, isEmpty, reason: 'still inside the debounce');

            // The whole burst collapses to one fire, on the last rebuilt
            // timer's target: trailing after the last rebuild. That is at
            // most the tolerance early and never late.
            async.elapse(trailing);
            final lastRebuild = perRebuild * (expected - 1);
            expect(fireTimes, [lastRebuild + trailing]);
            expect(
              fireTimes.single,
              greaterThanOrEqualTo(
                lastEvent + trailing - Coalescer.rescheduleTolerance,
              ),
              reason: 'trailing resolves at most the tolerance early',
            );
            expect(
              fireTimes.single,
              lessThanOrEqualTo(lastEvent + trailing),
              reason: 'the guard must never make trailing fire late',
            );
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              timersBuilt++;
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
      });
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
