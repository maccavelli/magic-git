import 'dart:async';

/// Holds a watcher tick that was suppressed as "probably our own echo", and
/// runs it later instead of throwing it away.
///
/// **Why suppression needed this.** Nearly every mutating action this app takes
/// touches `.git/index`, `HEAD` or `refs`, so the watcher fires a moment after
/// the app has already refreshed for that same change. Skipping that second
/// fetch is right. Skipping it by *dropping the tick* is not, because the tick
/// is not labelled: `OwnMutationTracker.isRecent` answers "did we mutate this
/// repo recently", not "is this particular event ours". A teammate's push
/// landing on the host, or a `git commit` the user runs in a terminal, inside
/// the same window is discarded with it.
///
/// The old code's defence was "a genuinely external change either lands outside
/// this window or is caught by the very next real tick". The first half fails
/// whenever the window is wide — and it is at its widest exactly when it is
/// least justified: `isRecent` stays true for the entire duration of an
/// in-flight operation, and `withOwnMutation` wraps the background fetch
/// (`app_providers.dart:1238`) and the 5-minute auto-fetch timer (`:3516`), a
/// pack transfer that can occupy tens of seconds. The second half assumes
/// another tick is coming; if the external change was the last event in the
/// burst, none is, and the app shows stale state until the user presses ⌘R.
///
/// So a suppressed tick is **deferred, not dropped**: [hold] arms one timer,
/// repeated holds inside that window coalesce into it, and when it fires the
/// tick is either re-held (the operation is still running) or flushed. The cost
/// is at most one extra refresh per [window] — the same order as what the
/// suppression saves — and the benefit is that no external change can be lost,
/// only delayed, by at most [maxDeferral].
///
/// MADR 0039 F6/H2.
class SuppressedTick {
  SuppressedTick({
    required this.onFlush,
    required this.stillSuppressed,
    this.window = const Duration(seconds: 3),
    Duration? maxDeferral,
    DateTime Function()? now,
  }) : maxDeferral = maxDeferral ?? window * 3,
       _now = now ?? DateTime.now;

  /// Runs the work the suppressed tick would have done.
  final void Function() onFlush;

  /// Whether the reason for suppressing is still true — normally the same
  /// `OwnMutationTracker.isRecent` call the caller used to suppress in the
  /// first place.
  final bool Function() stillSuppressed;

  /// How long to wait before re-checking. Matches the caller's suppression
  /// window, so a deferred tick lands as soon as the echo period is over.
  final Duration window;

  /// Total time a tick may be held before it is flushed regardless.
  ///
  /// This is the bound that stops an in-flight operation blinding the app for
  /// its whole duration. Defaults to three windows — long enough that an
  /// ordinary mutation's echo is absorbed, short enough that a multi-minute
  /// fetch cannot hide a teammate's push for multiple minutes.
  final Duration maxDeferral;

  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _heldSince;

  /// Whether a suppressed tick is waiting to be flushed — for tests.
  bool get isHolding => _heldSince != null;

  /// Records that a tick was suppressed.
  ///
  /// Arms the timer if none is armed; otherwise does nothing, which is the
  /// coalescing: a burst of suppressed ticks costs one flush, not one each.
  /// Deliberately does **not** re-arm — re-arming on every tick would let a
  /// steady event stream defer forever, which is the failure this class exists
  /// to prevent.
  void hold() {
    _heldSince ??= _now();
    _timer ??= Timer(window, _fire);
  }

  void _fire() {
    _timer = null;
    final since = _heldSince;
    if (since == null) return;
    if (stillSuppressed() && _now().difference(since) < maxDeferral) {
      _timer = Timer(window, _fire);
      return;
    }
    _heldSince = null;
    onFlush();
  }

  /// Drops any held tick without flushing. For `State.dispose`.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _heldSince = null;
  }
}
