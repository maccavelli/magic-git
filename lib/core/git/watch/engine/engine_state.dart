import '../source/watch_source.dart';

/// Where one watcher is in its life.
sealed class EngineState {
  const EngineState();
}

/// No attempt in play: built with no subscriber yet, or an arm aborted on its
/// own.
final class Idle extends EngineState {
  const Idle();
}

/// Arming for [attempt].
///
/// Carries no pending re-arm (MADR 0045 plan, deviation (i)). A request to
/// re-arm arrives only as a source's signal, and while this attempt arms the
/// only source that could send one is the one being replaced — whose attempt is
/// no longer current, so its request is dropped. Any number of requests
/// therefore collapse into the one arm already under way.
final class Arming extends EngineState {
  const Arming(this.attempt);
  final int attempt;
}

/// [source] armed for [attempt] and is reporting.
final class Armed extends EngineState {
  const Armed(this.attempt, this.source);
  final int attempt;
  final ArmedSource source;
}

/// [attempt]'s source died, and a restart is due once the backoff elapses.
final class BackingOff extends EngineState {
  const BackingOff(this.attempt);
  final int attempt;
}

/// Polling.
///
/// [reason] is the refusal that last degraded this watcher, or null when the
/// restart budget ran out with no refusal since the last successful arm.
final class Polling extends EngineState {
  const Polling(this.reason);
  final WatchUnavailableReason? reason;
}

/// The last subscriber left. Nothing is armed, recorded or emitted any more,
/// except to settle the arm that was in flight (MADR amendment 0045.2).
final class Stopped extends EngineState {
  const Stopped();
}
