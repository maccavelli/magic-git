import 'package:fake_async/fake_async.dart';

/// Lets in-flight arms decide, in fake time.
///
/// The fake-time successor of the real-time `settleArm` helper, which waited
/// 500 ms and then drained the event queue, because deciding an arm involved a
/// real timer (MADR 0041 phase 3) that `pumpEventQueue` alone did not advance.
/// Under `fakeAsync` the same 500 ms passes at once and the same way on every
/// run: whatever an arm does on a timer shorter than that still happens, and
/// whatever takes longer still does not (MADR 0045 phase 6).
extension ArmSettling on FakeAsync {
  void letArmsSettle() {
    elapse(const Duration(milliseconds: 500));
    flushMicrotasks();
  }
}
