/// Closed-loop cap on concurrent [ExecLane.read] commands, driven by how long
/// those commands actually take.
///
/// **Why not the link's RTT.** This used to band an idle keepalive ping into a
/// cap: `<80 ms → 4`, `80–200 ms → 3`, `>200 ms → 2`. Two things were wrong
/// with that, and neither was a threshold. The ping is suppressed while the
/// transport is busy (correctly — that is MADR 0011's fix for the health
/// monitor killing a healthy-but-busy session), so a sample could only ever be
/// taken when no command was in flight: the controller was structurally unable
/// to observe the load it existed to shed. And the thresholds were absolute, so
/// a 250 ms satellite link that is perfectly happy at four concurrent reads was
/// pinned to two, while a 40 ms link in real trouble was given four. Latency is
/// not congestion (0024 M1/A2).
///
/// **What it uses instead.** Every completed read-lane command reports its own
/// duration — samples that exist *because* commands are running, measured under
/// exactly the concurrency being controlled. Comparing the best duration seen
/// recently against the current smoothed one estimates queueing directly:
///
///   `gradient = minRtt / currentRtt`   (1.0 = no queue; falling = work piling up)
///
/// Applied as a **step**, not as a formula. The textbook gradient form
/// (`limit × gradient + sqrt(limit)`, from Netflix's `concurrency-limits`)
/// assumes limits in the hundreds where the allowance is proportionally small;
/// at a ceiling of 4 it dominates, and the controller provably cannot shrink at
/// any gradient — at `limit = 4` under 2x latency inflation it still returns 4
/// (0024 Amendment A2.1). One step per confirmed direction behaves correctly at
/// this magnitude.
///
/// A channel-open failure ([onChannelOpenError]) still drops an independent
/// error floor immediately: `MaxSessions` is a cliff, not a gradient.
library;

class AdaptiveReadConcurrency {
  AdaptiveReadConcurrency({
    this.ceiling = 4,
    this.noSampleCap = 3,
    this.consecutiveRequired = 3,
    this.warmupSamples = 10,
    this.onCapChanged,
    DateTime Function()? now,
  }) : _effective = noSampleCap,
       _desired = noSampleCap,
       _errorFloor = ceiling,
       _now = now ?? DateTime.now;

  /// Production max concurrent reads (matches [CommandLaneScheduler] default).
  final int ceiling;

  /// Cap used before [warmupSamples] durations have arrived.
  final int noSampleCap;

  /// Samples in the same direction required before the limit steps.
  final int consecutiveRequired;

  /// Durations needed before the controller acts at all. Below this the
  /// gradient is noise: `minRtt` and `currentRtt` are nearly the same number.
  final int warmupSamples;

  /// Invoked when the effective cap actually changes (wire to scheduler).
  final void Function(int cap)? onCapChanged;

  final DateTime Function() _now;

  /// EWMA weight for the current-duration estimate — ~14 samples of memory, so
  /// a handful of slow reads cannot swing the cap on their own.
  static const double alpha = 0.2;

  /// Gradient below this (latency inflated more than ~1.43x over the best seen)
  /// means work is queueing: step down.
  static const double shrinkBelow = 0.70;

  /// Gradient above this (within ~1.11x of the best seen) means there is
  /// headroom: step up.
  static const double growAbove = 0.90;

  /// The best-duration window. Re-anchored after this many samples or this much
  /// time, so a link that genuinely improves is not measured forever against an
  /// old best — and one that genuinely degrades is not permanently in "queueing".
  static const int minRttWindowSamples = 300;
  static const Duration minRttWindowAge = Duration(minutes: 5);

  int _effective;

  /// What the controller wants before the error floor is applied. Kept separate
  /// so a recovering error floor restores the cap the gradient asked for,
  /// rather than stranding it at whatever the floor had clamped it to.
  int _desired;

  int _errorFloor;
  int _successStreak = 0;

  int _samples = 0;
  int? _minRttMicros;
  double? _currentRttMicros;
  DateTime? _windowStart;
  int _windowSamples = 0;

  int _pendingDirection = 0;
  int _pendingCount = 0;

  /// Current effective max concurrent reads.
  int get effectiveCap => _effective;

  /// Best read duration in the current window, or null before any sample.
  Duration? get minRtt =>
      _minRttMicros == null ? null : Duration(microseconds: _minRttMicros!);

  /// Smoothed current read duration, or null before any sample.
  Duration? get currentRtt => _currentRttMicros == null
      ? null
      : Duration(microseconds: _currentRttMicros!.round());

  /// Queueing estimate in `(0, 1]`: 1.0 is no queue, falling means work is
  /// piling up. Null until the first sample.
  double? get gradient {
    final best = _minRttMicros;
    final current = _currentRttMicros;
    if (best == null || current == null || current <= 0) return null;
    final g = best / current;
    return g > 1.0 ? 1.0 : g;
  }

  void _commit(int candidate) {
    final next = candidate.clamp(1, _errorFloor).clamp(1, ceiling);
    if (next == _effective) return;
    _effective = next;
    onCapChanged?.call(_effective);
  }

  /// Feed one completed [ExecLane.read] command duration.
  void onReadSample(Duration duration) {
    final micros = duration.inMicroseconds;
    if (micros <= 0) return;
    _samples++;

    final now = _now();
    final start = _windowStart;
    final expired =
        start == null ||
        _windowSamples >= minRttWindowSamples ||
        now.difference(start) >= minRttWindowAge;
    if (_minRttMicros == null || expired) {
      _minRttMicros = micros;
      _windowStart = now;
      _windowSamples = 1;
    } else {
      if (micros < _minRttMicros!) _minRttMicros = micros;
      _windowSamples++;
    }

    final current = _currentRttMicros;
    _currentRttMicros = current == null
        ? micros.toDouble()
        : current * (1 - alpha) + micros * alpha;

    if (_samples < warmupSamples) return;

    final g = gradient;
    if (g == null) return;
    final direction = g < shrinkBelow ? -1 : (g > growAbove ? 1 : 0);
    if (direction == 0) {
      _pendingDirection = 0;
      _pendingCount = 0;
      return;
    }
    if (_pendingDirection == direction) {
      _pendingCount++;
    } else {
      _pendingDirection = direction;
      _pendingCount = 1;
    }
    if (_pendingCount < consecutiveRequired) return;
    _pendingCount = 0;
    _desired = (_desired + direction).clamp(1, ceiling);
    _commit(_desired);
  }

  /// A channel-open failure (typically MaxSessions) drops the cap immediately.
  void onChannelOpenError() {
    _errorFloor = (_effective - 1).clamp(1, ceiling);
    _pendingDirection = 0;
    _pendingCount = 0;
    _successStreak = 0;
    _commit(_errorFloor);
  }

  /// A successful command. After [consecutiveRequired] successes, the error
  /// floor rises one step toward [ceiling] and the cap returns to whatever the
  /// gradient controller last asked for.
  void onSuccess() {
    if (_errorFloor >= ceiling) {
      _successStreak = 0;
      return;
    }
    _successStreak++;
    if (_successStreak < consecutiveRequired) return;
    _successStreak = 0;
    _errorFloor = (_errorFloor + 1).clamp(1, ceiling);
    _commit(_desired);
  }

  /// Reset to the no-sample cap (on connect / disconnect).
  void reset() {
    _samples = 0;
    _minRttMicros = null;
    _currentRttMicros = null;
    _windowStart = null;
    _windowSamples = 0;
    _pendingDirection = 0;
    _pendingCount = 0;
    _successStreak = 0;
    _errorFloor = ceiling;
    _desired = noSampleCap;
    if (_effective != noSampleCap) {
      _effective = noSampleCap;
      onCapChanged?.call(_effective);
    }
  }
}
