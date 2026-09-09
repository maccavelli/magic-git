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
/// **Compared against what, though.** The gradient is only a queueing estimate
/// if `minRtt` and `currentRtt` describe the *same kind of work*. They did not.
/// Everything on the read lane fed one distribution, and that lane spans three
/// orders of magnitude of perfectly healthy work: a `git rev-parse` is about one
/// round trip, a `glab api` call has a 20 s timeout, and one branch-review batch
/// is up to 100 `git rev-list` walks under a 60 s timeout. `minRtt` was
/// therefore anchored by the cheapest command the session had ever issued, so
/// opening the Branches tab on a 500-ref repository drove the gradient far below
/// [shrinkBelow] and the controller shed concurrency — during the one gesture in
/// the app that most needs parallel reads. A healthy link throttled because the
/// user asked an expensive question. Samples are now bucketed by normalised
/// command (`CommandTelemetry.bucketLabel`) and each bucket carries its own
/// `minRtt`, EWMA and window, so a slow `rev-list` batch is compared against
/// other `rev-list` batches (MADR 0039 H1).
///
/// A channel-open failure ([onChannelOpenError]) still drops an independent
/// error floor immediately: `MaxSessions` is a cliff, not a gradient. Recovery
/// from that floor is time-based as well as count-based — see [errorMemory].
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

  /// Distinct command buckets tracked at once, least-recently-sampled evicted.
  ///
  /// [CommandTelemetry.bucketLabel] collapses `-c key=value` pairs, `--format`
  /// variants and every shell wrapper to `sh -c`, so a real session produces a
  /// small, stable set and this is never reached in practice. It is here because
  /// an unbounded map on a hot path is how the ignore oracle's own
  /// `_maxFilesPerRepo` bound came to exist.
  static const int maxBuckets = 64;

  /// How long a channel-open error is remembered for the purpose of sizing the
  /// next dwell. After this long without one, the escalation resets.
  static const Duration errorMemory = Duration(minutes: 15);

  /// First dwell after a channel-open error; each further recent error doubles
  /// it, capped at [maxFloorDwell].
  static const Duration baseFloorDwell = Duration(seconds: 30);
  static const Duration maxFloorDwell = Duration(minutes: 8);

  int _effective;

  /// What the controller wants before the error floor is applied. Kept separate
  /// so a recovering error floor restores the cap the gradient asked for,
  /// rather than stranding it at whatever the floor had clamped it to.
  int _desired;

  int _errorFloor;
  int _successStreak = 0;

  /// One bucket's view of the link. Insertion order in [_buckets] is the
  /// recency order used for eviction.
  final Map<String, _BucketStats> _buckets = {};

  /// The bucket that reported most recently — what the un-suffixed [minRtt],
  /// [currentRtt] and [gradient] getters describe.
  String? _lastBucket;

  int _pendingDirection = 0;
  int _pendingCount = 0;

  /// Channel-open errors inside [errorMemory], and when the last one landed.
  int _recentErrors = 0;
  DateTime? _lastErrorAt;

  /// The floor may not rise before this. Null when nothing is holding it.
  DateTime? _floorHoldUntil;

  /// Current effective max concurrent reads.
  int get effectiveCap => _effective;

  /// Best duration in the most-recently-sampled bucket's window, or null before
  /// any sample. Per bucket, because comparing a `rev-list` batch against a
  /// `rev-parse` measures the command, not the link.
  Duration? get minRtt {
    final b = _buckets[_lastBucket];
    return b?.minRttMicros == null
        ? null
        : Duration(microseconds: b!.minRttMicros!);
  }

  /// Smoothed duration in the most-recently-sampled bucket, or null.
  Duration? get currentRtt {
    final b = _buckets[_lastBucket];
    return b?.currentRttMicros == null
        ? null
        : Duration(microseconds: b!.currentRttMicros!.round());
  }

  /// Queueing estimate in `(0, 1]` for the most-recently-sampled bucket: 1.0 is
  /// no queue, falling means work is piling up. Null until that bucket has a
  /// sample.
  double? get gradient => gradientFor(_lastBucket);

  /// [gradient] for one command bucket, or null if it has no samples.
  double? gradientFor(String? bucket) {
    final b = bucket == null ? null : _buckets[bucket];
    final best = b?.minRttMicros;
    final current = b?.currentRttMicros;
    if (best == null || current == null || current <= 0) return null;
    final g = best / current;
    return g > 1.0 ? 1.0 : g;
  }

  /// Buckets currently tracked — for tests/diagnostics.
  int get bucketCount => _buckets.length;

  void _commit(int candidate) {
    final next = candidate.clamp(1, _errorFloor).clamp(1, ceiling);
    if (next == _effective) return;
    _effective = next;
    onCapChanged?.call(_effective);
  }

  /// Feed one completed [ExecLane.read] command duration.
  ///
  /// [bucket] is the command's normalised label — pass
  /// `CommandTelemetry.bucketLabel(gitArgs.join(' '))`. Samples are compared
  /// only against others in the same bucket, so an expensive command cannot read
  /// as congestion (MADR 0039 H1). The default exists for tests that feed one
  /// homogeneous population, which is exactly the single-bucket case.
  void onReadSample(Duration duration, {String bucket = '(test)'}) {
    final micros = duration.inMicroseconds;
    if (micros <= 0) return;

    // Re-insert so iteration order is least-recently-sampled first.
    final stats = _buckets.remove(bucket) ?? _BucketStats();
    _buckets[bucket] = stats;
    _lastBucket = bucket;
    while (_buckets.length > maxBuckets) {
      _buckets.remove(_buckets.keys.first);
    }

    stats.samples++;

    final now = _now();
    final start = stats.windowStart;
    final expired =
        start == null ||
        stats.windowSamples >= minRttWindowSamples ||
        now.difference(start) >= minRttWindowAge;
    if (stats.minRttMicros == null || expired) {
      stats.minRttMicros = micros;
      stats.windowStart = now;
      stats.windowSamples = 1;
    } else {
      if (micros < stats.minRttMicros!) stats.minRttMicros = micros;
      stats.windowSamples++;
    }

    final current = stats.currentRttMicros;
    stats.currentRttMicros = current == null
        ? micros.toDouble()
        : current * (1 - alpha) + micros * alpha;

    // Warmup is per bucket: below it the gradient is noise, because minRtt and
    // currentRtt for that command are still nearly the same number.
    if (stats.samples < warmupSamples) return;

    final g = gradientFor(bucket);
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

  /// A channel-open failure (typically MaxSessions) drops the cap immediately,
  /// and holds it down for a dwell that grows with how often this has been
  /// happening.
  ///
  /// Recovery used to be a bare count: [consecutiveRequired] successes and the
  /// floor rose. Reads complete constantly, so on a busy session that is a
  /// fraction of a second — and against a host with a genuinely hard limit
  /// (`MaxSessions 1..2`, a gateway, a rate limiter) the controller oscillated
  /// indefinitely: three successes, floor up, open error, floor down. Each cycle
  /// costs a failed channel open, which the Dashboard also counts as a transport
  /// error. The dwell makes it a circuit breaker instead — the floor must *hold*
  /// before it is probed again, and the hold doubles with each recent error
  /// (MADR 0039 H3).
  void onChannelOpenError() {
    final now = _now();
    final last = _lastErrorAt;
    if (last == null || now.difference(last) >= errorMemory) {
      _recentErrors = 1;
    } else {
      _recentErrors++;
    }
    _lastErrorAt = now;

    var dwell = baseFloorDwell * (1 << (_recentErrors - 1).clamp(0, 20));
    if (dwell > maxFloorDwell) dwell = maxFloorDwell;
    _floorHoldUntil = now.add(dwell);

    _errorFloor = (_effective - 1).clamp(1, ceiling);
    _pendingDirection = 0;
    _pendingCount = 0;
    _successStreak = 0;
    _commit(_errorFloor);
  }

  /// A successful **read**. After [consecutiveRequired] successes *and* once the
  /// dwell from the last channel-open error has elapsed, the error floor rises
  /// one step toward [ceiling] and the cap returns to whatever the gradient
  /// controller last asked for.
  ///
  /// Reads only — the caller enforces that. A commit or a fetch succeeding says
  /// nothing about how many parallel channels the host will grant, which is the
  /// same argument the sample path has always made.
  void onSuccess() {
    if (_errorFloor >= ceiling) {
      _successStreak = 0;
      return;
    }
    _successStreak++;
    if (_successStreak < consecutiveRequired) return;
    final hold = _floorHoldUntil;
    if (hold != null && _now().isBefore(hold)) {
      // Keep the streak: the floor is not being refused, only held. It rises on
      // the first success after the dwell rather than needing three more.
      return;
    }
    _successStreak = 0;
    _errorFloor = (_errorFloor + 1).clamp(1, ceiling);
    _commit(_desired);
  }

  /// Reset to the no-sample cap (on connect / disconnect).
  void reset() {
    _buckets.clear();
    _lastBucket = null;
    _pendingDirection = 0;
    _pendingCount = 0;
    _successStreak = 0;
    _recentErrors = 0;
    _lastErrorAt = null;
    _floorHoldUntil = null;
    _errorFloor = ceiling;
    _desired = noSampleCap;
    if (_effective != noSampleCap) {
      _effective = noSampleCap;
      onCapChanged?.call(_effective);
    }
  }
}

/// Per-command-bucket link statistics. See [AdaptiveReadConcurrency.onReadSample].
class _BucketStats {
  int samples = 0;
  int? minRttMicros;
  double? currentRttMicros;
  DateTime? windowStart;
  int windowSamples = 0;
}
