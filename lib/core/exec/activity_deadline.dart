import 'dart:async';

/// Wall-clock ceiling plus a stall timer that resets whenever [pulse] runs.
///
/// Used for fetch/push-style work that may legitimately outlive a short
/// timeout as long as bytes keep arriving, but must still die if the peer
/// goes silent or the transfer never ends.
class ActivityDeadline {
  ActivityDeadline({required this.idle, required this.ceiling})
    : _start = DateTime.now(),
      _last = DateTime.now();

  final Duration idle;
  final Duration ceiling;

  final DateTime _start;
  DateTime _last;

  /// Records that output arrived. Resets the stall timer.
  void pulse() => _last = DateTime.now();

  /// Completes with [inner], or a [TimeoutException] if [idle] elapses
  /// without a [pulse] or [ceiling] elapses from construction.
  Future<T> wait<T>(Future<T> inner) {
    final done = Completer<T>();
    Timer? idleTimer;
    Timer? ceilingTimer;

    void fail() {
      if (!done.isCompleted) {
        done.completeError(
          TimeoutException('activity deadline'),
          StackTrace.current,
        );
      }
    }

    void armIdle() {
      idleTimer?.cancel();
      final remaining = idle - DateTime.now().difference(_last);
      idleTimer = Timer(
        remaining < Duration.zero ? Duration.zero : remaining,
        () {
          if (DateTime.now().difference(_last) >= idle) {
            fail();
          } else {
            armIdle();
          }
        },
      );
    }

    final remainingCeiling = ceiling - DateTime.now().difference(_start);
    ceilingTimer = Timer(
      remainingCeiling < Duration.zero ? Duration.zero : remainingCeiling,
      fail,
    );
    armIdle();

    inner.then(
      (value) {
        if (!done.isCompleted) done.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );

    return done.future.whenComplete(() {
      idleTimer?.cancel();
      ceilingTimer?.cancel();
    });
  }
}
