import '../source/watch_source.dart';

/// Everything that can happen to one watcher, as its engine receives it.
///
/// A subscriber arriving or leaving, an arm finishing, a source reporting, a
/// timer firing, a budget slot freeing: each is one of these, handled one at a
/// time (MADR 0045 section 3). The outcome of work the engine started carries
/// the attempt that started it, so a late answer is recognised by comparison
/// rather than guarded against by position.
sealed class EngineEvent {
  const EngineEvent();
}

/// The first subscriber arrived.
final class Start extends EngineEvent {
  const Start();
}

/// Arming for [attempt] finished with [outcome].
final class ArmResolved extends EngineEvent {
  const ArmResolved(this.attempt, this.outcome);
  final int attempt;
  final SourceArm outcome;
}

/// Arming for [attempt] threw [error]: a transport blip, answered with a
/// restart.
final class ArmThrew extends EngineEvent {
  const ArmThrew(this.attempt, this.error);
  final int attempt;
  final Object error;
}

/// The source armed for [attempt] reported [signal].
final class Signalled extends EngineEvent {
  const Signalled(this.attempt, this.signal);
  final int attempt;
  final SourceSignal signal;
}

/// The backoff after [attempt]'s source died has elapsed.
final class RestartDue extends EngineEvent {
  const RestartDue(this.attempt);
  final int attempt;
}

/// A polling watcher's poll interval elapsed.
final class PollDue extends EngineEvent {
  const PollDue();
}

/// A polling watcher's recovery interval elapsed.
final class RecoveryDue extends EngineEvent {
  const RecoveryDue();
}

/// The host released a watcher budget slot.
final class BudgetReleased extends EngineEvent {
  const BudgetReleased();
}

/// The last subscriber left.
final class Cancel extends EngineEvent {
  const Cancel();
}
