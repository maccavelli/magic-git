/// Every duration and count the watcher stack uses, in one place.
///
/// These used to be repeated: the five coalescing and polling durations were
/// declared in four signatures, the re-arm debounce twice, and the timeouts
/// that must hold a relationship to one another — a 15-second release against
/// a three-minute grace, a 60-second heartbeat against a five-minute stale
/// lease — were related only by prose in doc comments (MADR 0045 F8).
///
/// Each value exists twice on purpose: as a `static const default…`, so a
/// parameter default or another constant can name it, and as an instance field,
/// so a test can shrink the whole set at once. Comparing `Duration`s is not a
/// constant expression, so the relationships cannot be constructor asserts;
/// [coherenceErrors] states them instead, and a test holds [standard] to them.
final class WatchTimings {
  const WatchTimings({
    this.trailing = defaultTrailing,
    this.maxWait = defaultMaxWait,
    this.minInterval = defaultMinInterval,
    this.pollInterval = defaultPollInterval,
    this.recoveryInterval = defaultRecoveryInterval,
    this.maxRestarts = defaultMaxRestarts,
    this.restartBackoffStep = defaultRestartBackoffStep,
    this.maxPathsPerTick = defaultMaxPathsPerTick,
    this.armSignalCeiling = defaultArmSignalCeiling,
    this.heartbeatInterval = defaultHeartbeatInterval,
    this.leaseStaleAfter = defaultLeaseStaleAfter,
    this.hostLeasePoll = defaultHostLeasePoll,
    this.releaseTimeout = defaultReleaseTimeout,
    this.sweepTimeout = defaultSweepTimeout,
    this.admissionGrace = defaultAdmissionGrace,
    this.rearmDebounce = defaultRearmDebounce,
    this.maxDiagnosticLines = defaultMaxDiagnosticLines,
    this.maxBufferChars = defaultMaxBufferChars,
  });

  /// Timings small enough for a test to run at fake speed, and still coherent.
  factory WatchTimings.forTest() => const WatchTimings(
    trailing: Duration.zero,
    maxWait: Duration(milliseconds: 10),
    minInterval: Duration.zero,
    pollInterval: Duration(milliseconds: 50),
    recoveryInterval: Duration(milliseconds: 200),
    restartBackoffStep: Duration(milliseconds: 10),
    armSignalCeiling: Duration(milliseconds: 20),
    heartbeatInterval: Duration(milliseconds: 100),
    leaseStaleAfter: Duration(milliseconds: 500),
    hostLeasePoll: Duration(milliseconds: 100),
    releaseTimeout: Duration(milliseconds: 50),
    sweepTimeout: Duration(milliseconds: 50),
    admissionGrace: Duration(milliseconds: 300),
    rearmDebounce: Duration(milliseconds: 20),
  );

  /// The timings the app runs with.
  static const standard = WatchTimings();

  /// Trailing edge of the coalescer: how long a burst must go quiet.
  static const defaultTrailing = Duration(milliseconds: 150);

  /// The longest a coalescer holds a continuous burst before firing anyway.
  static const defaultMaxWait = Duration(seconds: 1);

  /// The shortest gap between two coalesced ticks.
  static const defaultMinInterval = Duration(seconds: 1);

  /// How often a degraded repository polls.
  static const defaultPollInterval = Duration(seconds: 5);

  /// How often a polling repository retries event-driven watching.
  static const defaultRecoveryInterval = Duration(minutes: 3);

  /// Restarts spent before a watcher that keeps dying degrades to polling.
  static const defaultMaxRestarts = 3;

  /// Backoff per restart: the nth restart waits n times this.
  static const defaultRestartBackoffStep = Duration(seconds: 2);

  /// Distinct paths carried by one tick before it degrades to "unknown scope".
  static const defaultMaxPathsPerTick = 512;

  /// The longest an arm waits for a refusal or the readiness marker (MADR 0044).
  static const defaultArmSignalCeiling = Duration(seconds: 2);

  /// How often a live client refreshes its watcher's lease.
  static const defaultHeartbeatInterval = Duration(seconds: 60);

  /// A lease older than this means its client is gone.
  static const defaultLeaseStaleAfter = Duration(minutes: 5);

  /// How often the host-side lease loop re-reads the lease.
  static const defaultHostLeasePoll = Duration(seconds: 60);

  /// The command timeout for stamping or releasing a lease and lock.
  static const defaultReleaseTimeout = Duration(seconds: 15);

  /// The command timeout for one repository's connect-time sweep.
  static const defaultSweepTimeout = Duration(seconds: 20);

  /// The longest a new arm waits for a predecessor to give its lock back.
  static const defaultAdmissionGrace = Duration(minutes: 3);

  /// How long a bounded watch waits after a git-state event before re-arming.
  static const defaultRearmDebounce = Duration(seconds: 2);

  /// Watcher stderr lines forwarded as diagnostics per arm.
  static const defaultMaxDiagnosticLines = 20;

  /// Cap on an undelimited output buffer before it is dropped (1 MiB).
  static const defaultMaxBufferChars = 1 << 20;

  final Duration trailing;
  final Duration maxWait;
  final Duration minInterval;
  final Duration pollInterval;
  final Duration recoveryInterval;
  final int maxRestarts;
  final Duration restartBackoffStep;
  final int maxPathsPerTick;
  final Duration armSignalCeiling;
  final Duration heartbeatInterval;
  final Duration leaseStaleAfter;
  final Duration hostLeasePoll;
  final Duration releaseTimeout;
  final Duration sweepTimeout;
  final Duration admissionGrace;
  final Duration rearmDebounce;
  final int maxDiagnosticLines;
  final int maxBufferChars;

  /// One message per relationship these timings break; empty when coherent.
  ///
  /// Each rule is a coupling the stack depends on:
  ///
  /// * a lease or lock release must finish inside the grace a successor waits,
  ///   or the grace becomes the normal path rather than the backstop;
  /// * three heartbeats must fit inside a stale lease, so one slow link cannot
  ///   orphan a live watcher;
  /// * the host must re-read the lease more often than it goes stale;
  /// * the readiness wait must end before a release would time out;
  /// * the coalescer's trailing edge cannot outlast its own cap;
  /// * a polling repository must poll more often than it retries recovery.
  List<String> coherenceErrors() => [
    if (releaseTimeout >= admissionGrace)
      'releaseTimeout ($releaseTimeout) must be shorter than '
          'admissionGrace ($admissionGrace)',
    if (heartbeatInterval * 3 > leaseStaleAfter)
      'three heartbeatInterval ($heartbeatInterval) must fit inside '
          'leaseStaleAfter ($leaseStaleAfter)',
    if (hostLeasePoll >= leaseStaleAfter)
      'hostLeasePoll ($hostLeasePoll) must be shorter than '
          'leaseStaleAfter ($leaseStaleAfter)',
    if (armSignalCeiling >= releaseTimeout)
      'armSignalCeiling ($armSignalCeiling) must be shorter than '
          'releaseTimeout ($releaseTimeout)',
    if (trailing > maxWait)
      'trailing ($trailing) must not exceed maxWait ($maxWait)',
    if (pollInterval >= recoveryInterval)
      'pollInterval ($pollInterval) must be shorter than '
          'recoveryInterval ($recoveryInterval)',
  ];
}
