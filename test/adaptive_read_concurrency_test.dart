// AdaptiveReadConcurrency: RTT bands + hysteresis for the SSH read lane.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/adaptive_read_concurrency.dart';

void main() {
  test('band thresholds map RTT to cap', () {
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 40)),
      4,
    );
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 100)),
      3,
    );
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 250)),
      2,
    );
  });

  test('starts at no-sample cap and requires consecutive samples to change', () {
    final caps = <int>[];
    final a = AdaptiveReadConcurrency(
      consecutiveRequired: 3,
      onCapChanged: caps.add,
    );
    expect(a.effectiveCap, 3);

    // Two high-RTT samples are not enough.
    a.onRtt(const Duration(milliseconds: 300));
    a.onRtt(const Duration(milliseconds: 300));
    expect(a.effectiveCap, 3);
    expect(caps, isEmpty);

    // Third consecutive lands the change.
    a.onRtt(const Duration(milliseconds: 300));
    expect(a.effectiveCap, 2);
    expect(caps, [2]);
  });

  test('returning to current band clears pending hysteresis', () {
    final a = AdaptiveReadConcurrency(consecutiveRequired: 3);
    // Drive to 2.
    for (var i = 0; i < 3; i++) {
      a.onRtt(const Duration(milliseconds: 300));
    }
    expect(a.effectiveCap, 2);

    // Two low-RTT samples, then one high again — must not leave pending at 4.
    a.onRtt(const Duration(milliseconds: 20));
    a.onRtt(const Duration(milliseconds: 20));
    a.onRtt(const Duration(milliseconds: 300));
    expect(a.effectiveCap, 2);

    // Three low samples raise to ceiling.
    for (var i = 0; i < 3; i++) {
      a.onRtt(const Duration(milliseconds: 20));
    }
    expect(a.effectiveCap, 4);
  });

  test('reset returns to no-sample cap', () {
    final caps = <int>[];
    final a = AdaptiveReadConcurrency(onCapChanged: caps.add);
    for (var i = 0; i < 3; i++) {
      a.onRtt(const Duration(milliseconds: 300));
    }
    expect(a.effectiveCap, 2);
    a.reset();
    expect(a.effectiveCap, 3);
    expect(caps.last, 3);
  });
}
