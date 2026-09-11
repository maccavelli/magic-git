import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../../bounded_watch.dart';
import '../../coalescer.dart';
import '../../watch_diagnostics.dart';
import '../../watch_event.dart';
import '../source/watch_source.dart';
import '../watch_timings.dart';
import 'engine_event.dart';
import 'engine_state.dart';

/// One watcher's sequencing: arming, restarts with backoff, degrading to
/// polling and recovering from it, coalescing paths into ticks, and teardown.
///
/// It replaces the lifecycle function in `watch_lifecycle.dart` (MADR 0045
/// section 3), keeping its rules — the nine tests that specified that function
/// specify this class — and not its shape. The function serialised arms with a
/// promise chain, a queue counter and cancellation checks between awaits, and
/// each defect found in it was a late result landing on newer state (0026 H1,
/// MADR 0043 F2 and F3, amendment 0043.1). Here every input is an
/// [EngineEvent] handled one at a time, the outcome of anything the engine
/// starts carries the attempt that started it, and a result for an attempt
/// that is no longer current is dropped by comparison.
///
/// The rules it keeps:
/// - An arm emits one `eventDriven` tick, so the status dot turns green before
///   the first change arrives. It does not reset the restart budget: only a
///   real event proves the source healthy.
/// - A refusal polls every [WatchTimings.pollInterval] and retries every
///   [WatchTimings.recoveryInterval]; a released budget slot wakes a ceiling
///   refusal at once (0028 H2).
/// - A death emits a `stopped` tick and backs off `restarts` times
///   [WatchTimings.restartBackoffStep], and polls once
///   [WatchTimings.maxRestarts] are spent.
/// - A re-arm spends no budget and emits no `stopped` tick (0022 H5).
/// - Past [WatchTimings.maxPathsPerTick] distinct paths a tick carries none,
///   which consumers read as "anything may have changed".
final class WatchEngine {
  WatchEngine({
    required this.source,
    required this.repoPath,
    this.bounded,
    this.timings = WatchTimings.standard,
    this.onTransition,
    this.onPollingRecoveryAttempt,
    this.budgetReleased,
  }) {
    _controller = StreamController<RepoWatchEvent>(
      onListen: () => _post(const Start()),
      onCancel: () {
        _post(const Cancel());
        return _stopped.future;
      },
    );
  }

  /// What arms the watcher.
  final WatchSource source;

  final String repoPath;

  /// The bounded surface, resolved by the source on every arm; null for a
  /// recursive watch.
  final BoundedWatchSpecSource? bounded;

  final WatchTimings timings;

  /// Records mode transitions for diagnosis (MADR 0026). Purely observational:
  /// every transition reported here already happened, and reporting one must
  /// never change which happen or when.
  final WatchTransitionSink? onTransition;

  /// Called before each recovery arm from polling, so a source can drop what
  /// it cached — enough time has passed that the host is worth asking again.
  final void Function()? onPollingRecoveryAttempt;

  /// Fires when the host releases a watcher budget slot.
  ///
  /// A watcher refused by the ceiling waits on a condition this resolves, so it
  /// re-arms at once rather than polling out a recovery interval — up to three
  /// minutes at 48 host processes per minute, and forever if the slots stay
  /// occupied (0028 H2). No other refusal is woken by it: a freed slot says
  /// nothing about a host with no watcher tool.
  final Stream<void>? budgetReleased;

  /// The watcher's ticks. Listening arms it; cancelling tears it down, and the
  /// cancel completes once the source has closed.
  Stream<RepoWatchEvent> get events => _controller.stream;

  late final StreamController<RepoWatchEvent> _controller;
  final _mailbox = Queue<EngineEvent>();
  var _draining = false;
  EngineState _state = const Idle();
  var _attempt = 0;
  var _restarts = 0;

  /// The mode ticks carry. Not derived from [_state]: activity while polling
  /// makes ticks event-driven while the poll continues, as it always has.
  var _mode = WatchMode.stopped;

  /// The refusal that last degraded this watcher, cleared by a successful arm.
  WatchUnavailableReason? _degradedReason;

  /// The latest adopted source. Kept past its death, through backoff and a
  /// budget-spent poll, until the next arm or the cancel closes it.
  ArmedSource? _source;
  StreamSubscription<SourceSignal>? _sourceSignals;
  StreamSubscription<void>? _budgetSubscription;
  Coalescer? _coalescer;
  Timer? _pollTimer;
  Timer? _restartTimer;
  Timer? _recoveryTimer;

  /// Completes when the last subscriber leaves; handed to every arm, which
  /// races its waits against it.
  final _cancelled = Completer<void>();

  /// Completes once a cancel's teardown has finished.
  final _stopped = Completer<void>();

  // The paths seen since the last tick. A poll or restart tick drains them
  // too, and one with none is the documented "unknown scope".
  final _pending = <String>{};
  var _overflowed = false;

  /// Delivers [event] as if it had happened, for a test that must produce an
  /// input the public API cannot — a result from a superseded attempt.
  @visibleForTesting
  void debugPost(EngineEvent event) => _post(event);

  void _post(EngineEvent event) {
    _mailbox.add(event);
    // An input arriving while one is handled — a synchronous signal, a cancel
    // from inside a listener — waits its turn, so no handler ever sees state
    // another has half changed.
    if (_draining) return;
    _draining = true;
    try {
      while (_mailbox.isNotEmpty) {
        _handle(_mailbox.removeFirst());
      }
    } finally {
      _draining = false;
    }
  }

  void _handle(EngineEvent event) {
    switch (event) {
      case ArmResolved(:final attempt, :final outcome):
        _onArmResolved(attempt, outcome);
      case _ when _state is Stopped:
        return;
      case Start():
        _onStart();
      case ArmThrew(:final attempt):
        if (attempt == _attempt) _scheduleRestart();
      case Signalled(:final attempt, :final signal):
        if (attempt == _attempt) _onSignal(signal);
      case RestartDue(:final attempt):
        if (attempt == _attempt) _arm();
      case PollDue():
        _emit();
      case RecoveryDue():
        _onRecoveryDue();
      case BudgetReleased():
        _onBudgetReleased();
      case Cancel():
        _onCancel();
    }
  }

  void _onStart() {
    _budgetSubscription = budgetReleased?.listen(
      (_) => _post(const BudgetReleased()),
    );
    _arm();
  }

  /// Begins the next attempt: everything the last one left running stops now,
  /// and its source closes before the new one arms.
  void _arm() {
    final attempt = ++_attempt;
    _state = Arming(attempt);
    // Without cancelling the poll, a recovery from polling left it running
    // beside the event-driven watcher for the rest of the session.
    _pollTimer?.cancel();
    _pollTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _restartTimer?.cancel();
    _restartTimer = null;

    final previous = _source;
    _source = null;
    // Stopped now rather than after the close: whatever the replaced source
    // reports from here carries an attempt that is no longer current. Not
    // awaited — the close is the source's teardown, and a cancel's future
    // carries nothing the next arm waits on.
    unawaited(_sourceSignals?.cancel());
    _sourceSignals = null;
    _coalescer?.cancel();
    _mode = WatchMode.eventDriven;
    _coalescer = Coalescer(
      trailing: timings.trailing,
      maxWait: timings.maxWait,
      minInterval: timings.minInterval,
      onFire: _emit,
    );
    unawaited(_armAttempt(attempt, previous));
  }

  Future<void> _armAttempt(int attempt, ArmedSource? previous) async {
    try {
      // The replaced source gives back what it claimed before the next one
      // asks for it.
      if (previous != null) await previous.close();
      if (_cancelled.isCompleted) return;
      final outcome = await source.arm(
        ArmRequest(
          repoPath: repoPath,
          bounded: bounded,
          cancelled: _cancelled.future,
          attempt: attempt,
        ),
      );
      _post(ArmResolved(attempt, outcome));
    } catch (error) {
      _post(ArmThrew(attempt, error));
    }
  }

  void _onArmResolved(int attempt, SourceArm outcome) {
    // A superseded attempt's result is not adopted, and a source it carries is
    // closed: adopting a late arm is how one live watcher was left with
    // nothing holding it (0026 H1).
    if (attempt != _attempt) {
      if (outcome case SourceArmed(source: final superseded)) {
        unawaited(superseded.close());
      }
      return;
    }
    if (_state is Stopped) {
      _settleAfterCancel(outcome);
      return;
    }
    switch (outcome) {
      case SourceArmed(source: final armed):
        _source = armed;
        _sourceSignals = armed.signals.listen(
          (signal) => _post(Signalled(attempt, signal)),
        );
        _degradedReason = null;
        _state = Armed(attempt, armed);
        _record(WatchTransition.armed, 'arm succeeded');
        _emit();
      case SourceUnavailable(:final reason):
        _degradedReason = reason;
        _startPolling('arm unavailable: ${reason.name}');
      case SourceAborted():
        _state = const Idle();
        _record(WatchTransition.stopped, 'arm aborted');
    }
  }

  /// The arm that was in flight when the last subscriber left (MADR amendment
  /// 0045.2).
  void _settleAfterCancel(SourceArm outcome) {
    switch (outcome) {
      case SourceArmed(source: final orphan):
        // Armed for nobody: nothing else will ever close it.
        unawaited(orphan.close());
      case SourceAborted():
        _record(WatchTransition.stopped, 'arm aborted');
      case SourceUnavailable():
        // Neither recorded nor polled. The lifecycle function did both, and
        // its poll and recovery timers then ran for a stream that was gone.
        break;
    }
  }

  void _onSignal(SourceSignal signal) {
    switch (signal) {
      case PathChanged(:final path):
        if (_pending.length >= timings.maxPathsPerTick) {
          _overflowed = true;
          _pending.clear();
        }
        if (!_overflowed) _pending.add(path);
        _coalescer?.signal();
      case SourceActivity():
        if (_mode == WatchMode.polling) {
          _record(WatchTransition.recovered, 'event received');
        }
        _restarts = 0;
        _mode = WatchMode.eventDriven;
      case RearmRequested():
        _record(WatchTransition.rearmed, 'watched paths changed');
        // What the source covers changed; it did not die. So no mode change,
        // no backoff and no budget spent — or staging a file would flicker the
        // dot to stopped, and three edits in new directories would poll the
        // repository for the rest of the session (0022 H5).
        _arm();
      case SourceDied():
        _scheduleRestart();
    }
  }

  void _scheduleRestart() {
    if (_restarts >= timings.maxRestarts) {
      _startPolling('restart budget spent ($_restarts/${timings.maxRestarts})');
      return;
    }
    _record(WatchTransition.restartScheduled, 'source died');
    // Emitted at once, so the dot goes grey for the whole backoff instead of
    // staying green through a real outage.
    _mode = WatchMode.stopped;
    _emit();
    _restarts++;
    final attempt = _attempt;
    _state = BackingOff(attempt);
    _restartTimer?.cancel();
    _restartTimer = Timer(
      timings.restartBackoffStep * _restarts,
      () => _post(RestartDue(attempt)),
    );
  }

  void _startPolling(String cause) {
    _record(WatchTransition.degradedToPolling, cause);
    _mode = WatchMode.polling;
    _state = Polling(_degradedReason);
    _pollTimer?.cancel();
    _emit();
    _pollTimer = Timer.periodic(
      timings.pollInterval,
      (_) => _post(const PollDue()),
    );
    // A degraded watcher must not stay degraded for the session: a recovered
    // network, a newly installed tool or a settled volume is picked back up.
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer.periodic(
      timings.recoveryInterval,
      (_) => _post(const RecoveryDue()),
    );
  }

  void _onRecoveryDue() {
    _restarts = 0;
    _record(WatchTransition.recoveryAttempted, 'poll recovery');
    onPollingRecoveryAttempt?.call();
    _arm();
  }

  void _onBudgetReleased() {
    if (_state case Polling(
      reason: WatchUnavailableReason.ceiling,
    ) when _mode == WatchMode.polling) {
      _restarts = 0;
      _record(WatchTransition.recoveryAttempted, 'watcher slot released');
      _arm();
    }
  }

  void _onCancel() {
    _record(WatchTransition.stopped, 'stream cancelled');
    _state = const Stopped();
    if (!_cancelled.isCompleted) _cancelled.complete();
    _restartTimer?.cancel();
    _pollTimer?.cancel();
    _recoveryTimer?.cancel();
    _stopped.complete(_stop());
  }

  Future<void> _stop() async {
    // Nothing is handled once stopped, so neither subscription holds anything
    // worth waiting for.
    unawaited(_budgetSubscription?.cancel());
    _budgetSubscription = null;
    unawaited(_sourceSignals?.cancel());
    _sourceSignals = null;
    // Stopped adopts nothing, so the source read here is the last one. A tick
    // already due while it closes is still delivered, as it always was.
    final armed = _source;
    _source = null;
    if (armed != null) await armed.close();
    _coalescer?.cancel();
    _coalescer = null;
    if (!_controller.isClosed) await _controller.close();
  }

  void _emit() {
    if (_controller.isClosed) return;
    final paths = _overflowed ? const <String>{} : Set<String>.from(_pending);
    _pending.clear();
    _overflowed = false;
    _controller.add(
      RepoWatchEvent(at: DateTime.now(), mode: _mode, paths: paths),
    );
  }

  void _record(WatchTransition kind, String cause) =>
      onTransition?.call(kind, cause, _restarts);
}
