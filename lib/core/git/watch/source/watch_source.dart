import '../../bounded_watch.dart';

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

/// Why an arm could not produce a live source.
///
/// The engine used to see one undifferentiated `WatchUnavailable` and answer
/// every cause with the same 3-minute recovery. They are not the same kind of
/// condition: [ceiling] is transient and resolves the instant another watcher
/// stops — it is a property of this process, not of the host — where [noTool]
/// persists until the host itself changes. 0028 H2.
enum WatchUnavailableReason {
  /// No `inotifywait`/`fswatch` on the host. Persists until the host changes.
  noTool,

  /// This process already holds its maximum concurrent watchers. Transient,
  /// and resolves the moment any watcher is released.
  ceiling,

  /// The SSH stream budget is exhausted (0024 M2). Semi-persistent.
  streamBudget,

  /// A bounded spec matched no existing paths yet. Transient — resolves as
  /// tracked files appear.
  noWatchedPaths,

  /// Another live watcher already holds this repository on the host — a second
  /// session, a second tab reaching the same path by a different saved
  /// connection, or a second copy of the app (MADR 0041 F12).
  ///
  /// Deliberately NOT woken by a released watcher slot: a slot freeing up in
  /// this process says nothing about a lock held in another. This one waits for
  /// the recovery timer, as every refusal but [ceiling] does.
  heldByAnother,
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
