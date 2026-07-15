/// Maps recent SSH link RTT samples to an effective [maxConcurrentReads].
///
/// High RTT / saturated links benefit from fewer concurrent compressed reads
/// (less MaxSessions pressure, less keepalive starvation). Low RTT keeps the
/// production ceiling of 4. Never raises above [ceiling] — dual-client is the
/// path to more capacity, not a higher single-connection read fan-out.
///
/// Hysteresis: a candidate band must be observed for [consecutiveRequired]
/// samples in a row before the effective cap changes, so jitter does not thrash
/// 4↔3↔2.
class AdaptiveReadConcurrency {
  AdaptiveReadConcurrency({
    this.ceiling = 4,
    this.noSampleCap = 3,
    this.consecutiveRequired = 3,
    this.onCapChanged,
  }) : _effective = noSampleCap;

  /// Production max concurrent reads (matches [CommandLaneScheduler] default).
  final int ceiling;

  /// Cap used before any RTT samples arrive (conservative vs full ceiling).
  final int noSampleCap;

  /// Samples in the new band required before applying a change.
  final int consecutiveRequired;

  /// Invoked when the effective cap actually changes (wire to scheduler).
  final void Function(int cap)? onCapChanged;

  int _effective;
  int? _pendingBand;
  int _pendingCount = 0;

  /// Current effective max concurrent reads.
  int get effectiveCap => _effective;

  /// Band thresholds (median RTT):
  /// - &lt; 80ms → [ceiling] (typically 4)
  /// - 80–200ms → 3
  /// - &gt; 200ms → 2
  static int bandForRtt(Duration rtt, {int ceiling = 4}) {
    final ms = rtt.inMilliseconds;
    if (ms < 80) return ceiling.clamp(1, ceiling);
    if (ms <= 200) return 3.clamp(1, ceiling);
    return 2.clamp(1, ceiling);
  }

  /// Feed one answered keepalive RTT. May update [effectiveCap] after hysteresis.
  void onRtt(Duration rtt) {
    final band = bandForRtt(rtt, ceiling: ceiling);
    if (band == _effective) {
      _pendingBand = null;
      _pendingCount = 0;
      return;
    }
    if (_pendingBand == band) {
      _pendingCount++;
    } else {
      _pendingBand = band;
      _pendingCount = 1;
    }
    if (_pendingCount >= consecutiveRequired) {
      _effective = band;
      _pendingBand = null;
      _pendingCount = 0;
      onCapChanged?.call(_effective);
    }
  }

  /// Reset to the no-sample cap (on connect / disconnect).
  void reset() {
    _pendingBand = null;
    _pendingCount = 0;
    if (_effective != noSampleCap) {
      _effective = noSampleCap;
      onCapChanged?.call(_effective);
    }
  }
}
