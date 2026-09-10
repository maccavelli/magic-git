// MADR 0045 phase 1. The relationships between the watcher's timings were held
// only by prose — "coupled", "load-bearing" — in the doc comments of two files.
// These hold them in code.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';

void main() {
  test('the standard timings are coherent', () {
    expect(WatchTimings.standard.coherenceErrors(), isEmpty);
  });

  test('a release timeout at or above the admission grace is incoherent', () {
    const timings = WatchTimings(
      releaseTimeout: Duration(minutes: 3),
      admissionGrace: Duration(minutes: 3),
    );
    expect(
      timings.coherenceErrors(),
      anyElement(contains('releaseTimeout')),
      reason:
          'a successor would wait out the whole grace behind a release that '
          'has not timed out yet',
    );
  });

  test('three heartbeats that outlast the stale lease are incoherent', () {
    const timings = WatchTimings(
      heartbeatInterval: Duration(minutes: 2),
      leaseStaleAfter: Duration(minutes: 5),
    );
    expect(
      timings.coherenceErrors(),
      anyElement(contains('heartbeatInterval')),
      reason: 'one slow link would let the host reclaim a live watcher',
    );
  });

  test('forTest keeps every rule', () {
    expect(WatchTimings.forTest().coherenceErrors(), isEmpty);
  });
}
