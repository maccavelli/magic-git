import 'dart:async';

/// Awaits [future], failing with [TimeoutException] if it doesn't complete
/// within [timeout] — except that the clock doesn't count time spent with
/// [isPaused] reporting true. Checked each time the timeout would otherwise
/// fire: if still paused, the wait is extended by another [timeout] and
/// checked again, so pausing never grants exactly [timeout] regardless of how
/// long the pause lasts.
///
/// Built for SSH host-key verification: authenticating a connection is
/// bounded by a short timeout to fail fast on a genuinely hung network, but
/// verifying a *changed* host key pauses on an explicit human decision (via a
/// dialog), which can legitimately take far longer than that budget. Without
/// this, a user who takes more than the timeout to read a security-relevant
/// prompt would have their connection attempt fail out from under them.
Future<T> awaitWithPausableTimeout<T>(
  Future<T> future,
  Duration timeout, {
  required bool Function() isPaused,
}) {
  final completer = Completer<T>();
  Timer? timer;

  void arm() {
    timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      if (isPaused()) {
        arm();
      } else {
        completer.completeError(TimeoutException('Timed out after $timeout'));
      }
    });
  }

  arm();
  future.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    },
  );

  return completer.future.whenComplete(() => timer?.cancel());
}
