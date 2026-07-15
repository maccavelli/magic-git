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

  test('band boundaries are inclusive at 80ms and 200ms edges', () {
    // < 80 → ceiling; 80–200 inclusive upper → 3; > 200 → 2
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 79)),
      4,
    );
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 80)),
      3,
    );
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 200)),
      3,
    );
    expect(
      AdaptiveReadConcurrency.bandForRtt(const Duration(milliseconds: 201)),
      2,
    );
  });

  test('bandForRtt never exceeds the given ceiling', () {
    expect(
      AdaptiveReadConcurrency.bandForRtt(
        const Duration(milliseconds: 10),
        ceiling: 2,
      ),
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

  test('mixed intermediate band (80–200ms) settles at 3', () {
    final a = AdaptiveReadConcurrency(consecutiveRequired: 2);
    a.onRtt(const Duration(milliseconds: 120));
    a.onRtt(const Duration(milliseconds: 150));
    expect(a.effectiveCap, 3);
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

  test('reset while already at no-sample cap is a no-op for onCapChanged', () {
    final caps = <int>[];
    final a = AdaptiveReadConcurrency(onCapChanged: caps.add);
    expect(a.effectiveCap, 3);
    a.reset();
    expect(caps, isEmpty);
  });
}
