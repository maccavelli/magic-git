// AdaptiveReadConcurrency: a closed-loop read-lane limiter driven by command
// durations (0024 M1/A2). The RTT band table it replaced is gone, and so are
// the five tests that asserted only that table's thresholds.
//
// MADR 0039 changed two things and the tests below follow both:
//  * H1 — samples are partitioned by normalised command, so an expensive
//    command can no longer read as congestion;
//  * H3 — the channel-open error floor is held for a dwell that grows with
//    repeated errors, so it can no longer oscillate against a hard MaxSessions.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/adaptive_read_concurrency.dart';

void main() {
  // 0024 M1/A2: the discriminating case. A 250 ms link with no queueing is a
  // satellite hop that is perfectly happy at the full ceiling; the band table
  // pins it to 2 unconditionally, because absolute latency is not congestion.
  test('a uniformly slow but unqueued link keeps its full read cap', () {
    final a = AdaptiveReadConcurrency();
    for (var i = 0; i < 20; i++) {
      a.onReadSample(const Duration(milliseconds: 250));
    }
    expect(a.effectiveCap, 4);
  });

  test('latency rising with concurrency sheds the cap', () {
    final a = AdaptiveReadConcurrency();
    // Establish a floor of ~50 ms...
    for (var i = 0; i < 12; i++) {
      a.onReadSample(const Duration(milliseconds: 50));
    }
    expect(a.effectiveCap, 4);
    // ...then the same host under load: 3x inflation, queueing.
    for (var i = 0; i < 12; i++) {
      a.onReadSample(const Duration(milliseconds: 150));
    }
    expect(a.effectiveCap, lessThan(4));
  });

  test('holds the no-sample cap through warm-up, then steps once', () {
    final caps = <int>[];
    final a = AdaptiveReadConcurrency(onCapChanged: caps.add);
    expect(a.effectiveCap, 3);

    // Below warmupSamples the gradient is noise and nothing may move.
    for (var i = 0; i < 9; i++) {
      a.onReadSample(const Duration(milliseconds: 40));
    }
    expect(a.effectiveCap, 3);
    expect(caps, isEmpty);

    // Past warm-up, an unqueued link takes consecutiveRequired samples in the
    // same direction before it steps — one step, not a jump.
    for (var i = 0; i < 3; i++) {
      a.onReadSample(const Duration(milliseconds: 40));
    }
    expect(a.effectiveCap, 4);
    expect(caps, [4]);
  });

  test('hysteresis: two samples in a direction are not enough', () {
    final a = AdaptiveReadConcurrency();
    for (var i = 0; i < 12; i++) {
      a.onReadSample(const Duration(milliseconds: 40));
    }
    expect(a.effectiveCap, 4);

    // A burst of queueing has to persist before the cap moves — a couple of
    // slow reads is what a passing hiccup looks like, and shedding on that
    // would thrash the read lane.
    a.onReadSample(const Duration(milliseconds: 400));
    a.onReadSample(const Duration(milliseconds: 400));
    expect(a.effectiveCap, 4, reason: 'two is not a trend');

    a.onReadSample(const Duration(milliseconds: 400));
    expect(a.effectiveCap, 3, reason: 'the third confirms it');
  });

  test('a step is one at a time, never a jump to the floor', () {
    final a = AdaptiveReadConcurrency();
    for (var i = 0; i < 12; i++) {
      a.onReadSample(const Duration(milliseconds: 40));
    }
    expect(a.effectiveCap, 4);
    // Sustained, severe queueing walks down one step per confirmation.
    for (var i = 0; i < 3; i++) {
      a.onReadSample(const Duration(seconds: 4));
    }
    expect(a.effectiveCap, 3);
    for (var i = 0; i < 3; i++) {
      a.onReadSample(const Duration(seconds: 4));
    }
    expect(a.effectiveCap, 2);
  });

  test('reset returns to no-sample cap', () {
    final caps = <int>[];
    final a = AdaptiveReadConcurrency(onCapChanged: caps.add);
    for (var i = 0; i < 13; i++) {
      a.onReadSample(const Duration(milliseconds: 40));
    }
    expect(a.effectiveCap, 4);
    a.reset();
    expect(a.effectiveCap, 3);
    expect(caps.last, 3);
  });

  test('reset while already at no-sample cap is a no-op for onCapChanged', () {
    final caps = <int>[];
    final a = AdaptiveReadConcurrency(onCapChanged: caps.add);
    expect(a.effectiveCap, 3);
    a.reset();
    expect(caps, isEmpty);
  });

  test('channel-open error drops the cap immediately, floor 1', () {
    final a = AdaptiveReadConcurrency();
    for (var i = 0; i < 13; i++) {
      a.onReadSample(const Duration(milliseconds: 20));
    }
    expect(a.effectiveCap, 4);
    a.onChannelOpenError();
    expect(a.effectiveCap, 3);
    a.onChannelOpenError();
    expect(a.effectiveCap, 2);
    a.onChannelOpenError();
    expect(a.effectiveCap, 1);
    a.onChannelOpenError();
    expect(a.effectiveCap, 1);
  });

  test(
    'the error floor recovers on three successes, once the dwell has elapsed',
    () {
      // AMENDED for MADR 0039 H3. This used to assert that three successes were
      // sufficient on their own. They are not any more, and that is the fix:
      // reads complete constantly, so a bare count restored the floor within a
      // fraction of a second and the controller oscillated against a host with
      // a hard limit. The floor still recovers — it just has to hold first.
      var now = DateTime(2026);
      final a = AdaptiveReadConcurrency(now: () => now);
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20));
      }
      expect(a.effectiveCap, 4);
      a.onChannelOpenError();
      expect(a.effectiveCap, 3);

      a.onSuccess();
      a.onSuccess();
      a.onSuccess();
      expect(
        a.effectiveCap,
        3,
        reason: 'the count is met but the dwell is not — the floor holds',
      );

      now = now.add(AdaptiveReadConcurrency.baseFloorDwell);
      a.onSuccess();
      expect(
        a.effectiveCap,
        4,
        reason:
            'the streak is kept across the hold, so recovery is immediate '
            'once the dwell passes rather than needing three more successes',
      );
    },
  );

  test('reset restores no-sample cap and clears the error floor', () {
    final a = AdaptiveReadConcurrency();
    a.onChannelOpenError();
    expect(a.effectiveCap, 2);
    a.reset();
    expect(a.effectiveCap, 3);
    for (var i = 0; i < 13; i++) {
      a.onReadSample(const Duration(milliseconds: 20));
    }
    expect(a.effectiveCap, 4);
  });

  group('H1 — samples are compared within their own command bucket', () {
    test('an expensive command does not read as congestion', () {
      // The discriminating case, and the one that used to shed the cap: a
      // session of cheap reads, then the user opens Branches on a 500-ref repo
      // and a handful of `sh -c` batches land, each two orders of magnitude
      // slower. Unbucketed, minRtt is anchored by `git rev-parse` and the
      // gradient collapses — throttling a healthy link because the user asked
      // an expensive question.
      final a = AdaptiveReadConcurrency();
      for (var i = 0; i < 13; i++) {
        a.onReadSample(
          const Duration(milliseconds: 20),
          bucket: 'git rev-parse',
        );
      }
      expect(a.effectiveCap, 4);

      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(seconds: 4), bucket: 'sh -c');
      }

      expect(
        a.effectiveCap,
        4,
        reason:
            'a slow batch is slow work, not a queue — it is compared '
            'against other batches, not against rev-parse',
      );
      expect(a.gradientFor('git rev-parse'), closeTo(1.0, 0.01));
      expect(a.gradientFor('sh -c'), closeTo(1.0, 0.01));
    });

    test('a bucket that genuinely inflates still sheds the cap', () {
      // The control. Without it the test above is satisfied by a controller
      // that has simply stopped working.
      final a = AdaptiveReadConcurrency();
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20), bucket: 'git status');
      }
      expect(a.effectiveCap, 4);

      // The SAME command, now three times slower: that is queueing.
      for (var i = 0; i < 40; i++) {
        a.onReadSample(const Duration(milliseconds: 60), bucket: 'git status');
      }

      expect(
        a.effectiveCap,
        lessThan(4),
        reason:
            'inflation within one bucket is exactly what the gradient is '
            'for, and must still be acted on',
      );
    });

    test('the bucket map is bounded', () {
      final a = AdaptiveReadConcurrency();
      for (var i = 0; i < AdaptiveReadConcurrency.maxBuckets * 3; i++) {
        a.onReadSample(const Duration(milliseconds: 20), bucket: 'cmd-$i');
      }
      expect(a.bucketCount, AdaptiveReadConcurrency.maxBuckets);
    });

    test('the un-suffixed getters describe the bucket that last reported', () {
      final a = AdaptiveReadConcurrency();
      a.onReadSample(const Duration(milliseconds: 20), bucket: 'fast');
      a.onReadSample(const Duration(seconds: 2), bucket: 'slow');
      expect(a.currentRtt, const Duration(seconds: 2));
      a.onReadSample(const Duration(milliseconds: 20), bucket: 'fast');
      expect(a.currentRtt, const Duration(milliseconds: 20));
    });
  });

  group('H3 — the error floor is a circuit breaker, not a counter', () {
    test('alternating errors and success bursts do not oscillate', () {
      var now = DateTime(2026);
      final caps = <int>[];
      final a = AdaptiveReadConcurrency(now: () => now, onCapChanged: caps.add);
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20));
      }
      caps.clear();

      // Ten rounds of "one refused channel, then a burst of successful reads" —
      // the steady state against a host with a hard MaxSessions. Each round used
      // to cost a cap change down and a cap change back up, and a wasted channel
      // open every time.
      for (var round = 0; round < 10; round++) {
        a.onChannelOpenError();
        for (var i = 0; i < 5; i++) {
          a.onSuccess();
        }
        now = now.add(const Duration(seconds: 1));
      }

      expect(
        caps.where((c) => c == 4),
        isEmpty,
        reason:
            'the floor must not climb back between errors — every return '
            'to 4 is a channel open the host is about to refuse again',
      );
      expect(a.effectiveCap, 1);
    });

    test('the dwell doubles with each recent error', () {
      var now = DateTime(2026);
      final a = AdaptiveReadConcurrency(now: () => now);
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20));
      }

      a.onChannelOpenError(); // first error → 30 s dwell
      a.onChannelOpenError(); // second → 60 s
      expect(a.effectiveCap, 2);

      now = now.add(const Duration(seconds: 45));
      for (var i = 0; i < 3; i++) {
        a.onSuccess();
      }
      expect(a.effectiveCap, 2, reason: '45 s is inside the doubled dwell');

      now = now.add(const Duration(seconds: 30));
      a.onSuccess();
      expect(a.effectiveCap, 3);
    });

    test('the escalation resets after a quiet period', () {
      var now = DateTime(2026);
      final a = AdaptiveReadConcurrency(now: () => now);
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20));
      }
      a.onChannelOpenError();
      a.onChannelOpenError();

      // A long healthy stretch: the next error is a first error again, not a
      // third, so one bad day does not permanently slow every later recovery.
      now = now.add(AdaptiveReadConcurrency.errorMemory);
      a.onChannelOpenError();
      now = now.add(AdaptiveReadConcurrency.baseFloorDwell);
      for (var i = 0; i < 3; i++) {
        a.onSuccess();
      }
      expect(a.effectiveCap, greaterThan(1));
    });

    test('reset clears the dwell as well as the floor', () {
      final now = DateTime(2026);
      final a = AdaptiveReadConcurrency(now: () => now);
      a.onChannelOpenError();
      a.reset();
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20));
      }
      expect(a.effectiveCap, 4, reason: 'a new session starts unencumbered');
    });
  });
}
