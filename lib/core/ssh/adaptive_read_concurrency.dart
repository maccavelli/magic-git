/// Maps recent SSH link RTT samples to an effective [maxConcurrentReads].
///
/// High RTT / saturated links benefit from fewer concurrent compressed reads
/// (less MaxSessions pressure, less keepalive starvation). Low RTT keeps the
/// production ceiling of 4. Never raises above [ceiling] — extra SSH clients
/// are the path to more capacity, not a higher single-connection read fan-out.
///
/// Hysteresis: a candidate RTT band must be observed for [consecutiveRequired]
/// samples in a row before the effective cap changes, so jitter does not thrash
/// 4↔3↔2. Channel-open errors drop an independent error floor (min 1) which
/// the RTT band is clamped to; a clean streak raises the floor back.
class AdaptiveReadConcurrency {
  AdaptiveReadConcurrency({
    this.ceiling = 4,
    this.noSampleCap = 3,
    this.consecutiveRequired = 3,
    this.onCapChanged,
  }) : _effective = noSampleCap,
       _errorFloor = ceiling;

  /// Production max concurrent reads (matches [CommandLaneScheduler] default).
  final int ceiling;

  /// Cap used before any RTT samples arrive (conservative vs full ceiling).
  final int noSampleCap;

  /// Samples in the new band required before applying a change.
  final int consecutiveRequired;

  /// Invoked when the effective cap actually changes (wire to scheduler).
  final void Function(int cap)? onCapChanged;

  int _effective;
  int _errorFloor;
  int? _lastRttBand;
  int? _pendingBand;
  int _pendingCount = 0;
  int _successStreak = 0;

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

  void _commit(int candidate) {
    final next = candidate.clamp(1, _errorFloor).clamp(1, ceiling);
    if (next == _effective) return;
    _effective = next;
    onCapChanged?.call(_effective);
  }

  /// Feed one answered keepalive RTT. May update [effectiveCap] after hysteresis.
  void onRtt(Duration rtt) {
    final band = bandForRtt(rtt, ceiling: ceiling);
    _lastRttBand = band;
    final target = band.clamp(1, _errorFloor).clamp(1, ceiling);
    if (target == _effective) {
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
      _pendingBand = null;
      _pendingCount = 0;
      _commit(band);
    }
  }

  /// A channel-open failure (typically MaxSessions) drops the cap immediately.
  void onChannelOpenError() {
    _errorFloor = (_effective - 1).clamp(1, ceiling);
    _pendingBand = null;
    _pendingCount = 0;
    _successStreak = 0;
    _commit(_errorFloor);
  }

  /// A successful command. After [consecutiveRequired] successes, the error
  /// floor rises one step toward [ceiling], clamped by the last RTT band.
  void onSuccess() {
    if (_errorFloor >= ceiling) {
      _successStreak = 0;
      return;
    }
    _successStreak++;
    if (_successStreak < consecutiveRequired) return;
    _successStreak = 0;
    _errorFloor = (_errorFloor + 1).clamp(1, ceiling);
    _commit(_lastRttBand ?? _effective);
  }

  /// Reset to the no-sample cap (on connect / disconnect).
  void reset() {
    _pendingBand = null;
    _pendingCount = 0;
    _successStreak = 0;
    _lastRttBand = null;
    _errorFloor = ceiling;
    if (_effective != noSampleCap) {
      _effective = noSampleCap;
      onCapChanged?.call(_effective);
    }
  }
}
