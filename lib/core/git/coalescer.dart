import 'dart:async';

/// Coalesces a bursty signal into occasional fires.
///
/// Combines three guards, per the file-watcher tuning established by research:
///  - a **trailing debounce** ([trailing]): fire only after the burst settles;
///  - a **maxWait ceiling** ([maxWait]): a continuous writer that keeps
///    resetting the trailing timer still fires within this bound;
///  - a **minimum interval** ([minInterval]): never fire sooner than this after
///    the previous fire, so a remote is never hammered.
///
/// **Precedence when they conflict:** [minInterval] wins over [maxWait]. These
/// two guarantees are about different things — [maxWait] bounds latency from
/// the *pending event's* perspective (don't let an ever-resetting trailing
/// timer debounce forever), while [minInterval] bounds *frequency* from the
/// firing side (don't call [onFire] too often). When a burst arrives shortly
/// after a recent fire and `minInterval > maxWait`, honoring the full
/// [minInterval] gap necessarily means this particular fire lands later than
/// [maxWait] since the burst started — that's intentional, not a missed
/// deadline: nothing about *this* burst's own debounce is left unresolved (it
/// isn't stuck endlessly resetting), it's simply waiting out the throttle from
/// the *previous* fire. See `coalescer_test.dart`'s "minInterval prevents
/// fires closer than the floor" for the pinned example. Callers that want
/// [maxWait] to be a hard, unconditional ceiling regardless of [minInterval]
/// should pass a [minInterval] no larger than [maxWait].
///
/// [now] is injectable so timing is deterministic under test.
class Coalescer {
  final Duration trailing;
  final Duration maxWait;
  final Duration minInterval;
  final void Function() onFire;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _firstPending;
  DateTime? _lastFire;

  Coalescer({
    required this.trailing,
    required this.maxWait,
    required this.minInterval,
    required this.onFire,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Records one incoming event and (re)schedules the next fire.
  void signal() {
    final now = _now();
    _firstPending ??= now;
    _timer?.cancel();

    // Trailing debounce, capped so total wait since the first pending event
    // never exceeds maxWait.
    var delay = trailing;
    final remainingToCap = maxWait - now.difference(_firstPending!);
    if (remainingToCap < delay) {
      delay = remainingToCap;
    }

    // Never fire sooner than minInterval after the previous fire.
    if (_lastFire != null) {
      final remainingMin = minInterval - now.difference(_lastFire!);
      if (remainingMin > delay) {
        delay = remainingMin;
      }
    }

    if (delay < Duration.zero) {
      delay = Duration.zero;
    }
    _timer = Timer(delay, _fire);
  }

  void _fire() {
    _lastFire = _now();
    _firstPending = null;
    _timer = null;
    onFire();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    // Reset the burst start too — a freshly constructed instance has no
    // pending burst (both null), and leaving this stale would make a later
    // signal() compute `remainingToCap` against a burst that no longer
    // exists, capping — and likely firing immediately at — a delay that
    // should instead be a fresh full `trailing`/`maxWait` cycle.
    _firstPending = null;
  }
}
