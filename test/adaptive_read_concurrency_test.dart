// AdaptiveReadConcurrency: a closed-loop read-lane limiter driven by command
// durations (0024 M1/A2). The RTT band table it replaced is gone, and so are
// the five tests that asserted only that table's thresholds.

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
    'three successes raise the error floor back to what the gradient wants',
    () {
      final a = AdaptiveReadConcurrency();
      for (var i = 0; i < 13; i++) {
        a.onReadSample(const Duration(milliseconds: 20));
      }
      expect(a.effectiveCap, 4);
      a.onChannelOpenError();
      expect(a.effectiveCap, 3);
      a.onSuccess();
      a.onSuccess();
      expect(a.effectiveCap, 3);
      a.onSuccess();
      expect(a.effectiveCap, 4);
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
}
