import 'package:flutter_test/flutter_test.dart';

/// Waits until an arm has actually decided, in real time.
///
/// Since MADR 0041 phase 3, **every** arm reads `handle.exitCode` with a 250 ms
/// cap before it commits, so that a script-level refusal — no watchable paths
/// (0022 M6), or another live watcher already holding the repository (0041 F12)
/// — is seen as a refusal rather than as a watcher that armed and died, which
/// would spend the restart budget on three doomed retries first.
///
/// That read is a real timer. `pumpEventQueue()` drains microtasks and events
/// but does not advance the clock, so on its own it returns while the arm is
/// still waiting and the test sees no transition at all:
///
/// ```text
/// Expected: contains WatchTransition:<WatchTransition.armed>
///   Actual: MappedListIterable<WatchTransitionRecord, WatchTransition>:[]
/// ```
///
/// A named helper rather than a delay written out at each call site, so the
/// reason travels with the wait and a future change to the read has one place
/// to look.
Future<void> settleArm() async {
  // 250 ms is the read's cap; the margin is for the round trips the arm makes
  // either side of it, and for a loaded machine.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await pumpEventQueue();
}
