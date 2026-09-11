import '../../bounded_watch.dart';
import '../../watch_lifecycle.dart' show WatchUnavailableReason;

/// The seam between "watch this repository" and how a backend does it.
///
/// A source arms one watcher and reports what happens to it as [SourceSignal]s.
/// It owns nothing about restarts, polling, coalescing or teardown order across
/// attempts — that is the engine's (MADR 0045 section 4). The remote arm used
/// to be one 503-line closure doing eight jobs (F6); behind this seam it is a
/// composition of units, each testable on its own.
abstract interface class WatchSource {
  /// Arms one watcher for [request], or says why it could not.
  Future<SourceArm> arm(ArmRequest request);
}

/// What a source is asked to arm.
///
/// Built from the service's parameters until phase 5 builds it from a
/// `WatchTarget` (plan decision (a)), so the seam lands before target identity
/// without migrating callers twice.
final class ArmRequest {
  const ArmRequest({
    required this.repoPath,
    required this.cancelled,
    required this.attempt,
    this.bounded,
  });

  final String repoPath;

  /// The bounded surface, resolved on every arm; null for a recursive watch.
  final BoundedWatchSpecSource? bounded;

  /// Completes when the caller no longer wants this watcher. A source races
  /// its waits against it and must not arm after it completes.
  final Future<void> cancelled;

  /// Which attempt this is, within the stream's life.
  final int attempt;
}

/// The outcome of [WatchSource.arm].
sealed class SourceArm {
  const SourceArm();
}

/// Armed: [source] is live and reporting.
final class SourceArmed extends SourceArm {
  const SourceArmed(this.source);
  final ArmedSource source;
}

/// Not armed, for a reason polling can wait out.
final class SourceUnavailable extends SourceArm {
  const SourceUnavailable(this.reason);
  final WatchUnavailableReason reason;
}

/// Not armed, because the request was cancelled while arming.
final class SourceAborted extends SourceArm {
  const SourceAborted();
}

/// A live watcher.
abstract interface class ArmedSource {
  /// What the watcher reports. Single-subscription, so nothing emitted between
  /// the arm returning and the engine listening is lost.
  Stream<SourceSignal> get signals;

  /// Tears the watcher down and gives back everything it claimed.
  Future<void> close();
}

/// One thing a live watcher reports.
sealed class SourceSignal {
  const SourceSignal();
}

/// A repository-relative path changed, already filtered.
final class PathChanged extends SourceSignal {
  const PathChanged(this.path);
  final String path;
}

/// The watcher produced output — proof it is alive, which resets the engine's
/// restart budget.
final class SourceActivity extends SourceSignal {
  const SourceActivity();
}

/// What the watcher covers has changed and it should be re-armed — not
/// because it died.
final class RearmRequested extends SourceSignal {
  const RearmRequested();
}

/// The watcher ended on its own, for [cause].
final class SourceDied extends SourceSignal {
  const SourceDied(this.cause);
  final String cause;
}
