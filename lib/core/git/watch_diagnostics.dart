/// A bounded, in-memory record of every mode transition `watchLifecycle`
/// performs, so "why is this repo polling?" is answerable from inside the app.
///
/// MADR 0026. A live measurement found the degraded-poll path issuing **48 git
/// processes per minute** with no user action — 53 % of everything observed on
/// the host — while live `inotifywait` processes existed for the very repo
/// being polled. Host-side tools cannot explain that: `trace2` logs git
/// invocations and `/proc` lists processes, but neither knows what mode the
/// engine believed it was in, or why. Nothing recorded that. This does.
///
/// It is deliberately **observational**: every transition below already happens
/// today, and recording one must not change which happen or when. Nothing here
/// issues a command, spawns a process, or touches the host.
library;

/// A mode change the watcher engine performed.
enum WatchTransition {
  /// A watch source armed successfully and is delivering events.
  armed,

  /// An arm attempt did not produce a live source. See [WatchTransitionRecord.cause]
  /// for which refusal it was — the engine collapses them all to
  /// `WatchUnavailable`, which is the distinction MADR 0026 needs back.
  armFailed,

  /// The source died and a re-arm was scheduled with backoff.
  restartScheduled,

  /// The restart budget was spent (or no source was available): the engine
  /// fell back to the poll timer. **This is the expensive state.**
  degradedToPolling,

  /// A periodic attempt to climb back out of polling.
  recoveryAttempted,

  /// Event-driven watching resumed after polling.
  recovered,

  /// A deliberate re-arm because the watched path set changed — not a death.
  rearmed,

  /// The watch was torn down (stream cancelled).
  stopped,
}

/// One transition, with the state that discriminates MADR 0026's hypotheses.
///
/// [liveWatchers] and [restarts] are the load-bearing fields: a refusal with
/// `liveWatchers` at the ceiling while no watcher process exists on the host
/// means a **slot** leaked (H1), where repeated [restartScheduled] before a
/// degradation means the **source** kept dying (H3).
class WatchTransitionRecord {
  const WatchTransitionRecord({
    required this.at,
    required this.kind,
    required this.repoPath,
    required this.cause,
    required this.liveWatchers,
    required this.restarts,
  });

  final DateTime at;
  final WatchTransition kind;
  final String repoPath;

  /// Why this transition happened, in the engine's own terms — `'ceiling 2/2'`,
  /// `'onDone'`, `'no tool'`, `'stream budget'`, `'no paths'`. Free text on
  /// purpose: it is read by a maintainer, not matched by code.
  final String cause;

  /// `RemoteWatchService.liveWatchers` at this instant.
  final int liveWatchers;

  /// The engine's spent restart budget at this instant.
  final int restarts;

  @override
  String toString() =>
      '${at.toIso8601String()} ${kind.name} $repoPath '
      'cause=$cause live=$liveWatchers restarts=$restarts';
}

/// How the engine reports a transition to whoever is recording it.
///
/// The engine is transport-agnostic: it knows the transition, why it happened,
/// and its own restart budget, but not the repository path or how many watcher
/// processes the transport is holding. The service supplies those.
typedef WatchTransitionSink =
    void Function(WatchTransition kind, String cause, int restarts);

/// The transition history for one repository.
class WatchTransitionLog {
  /// Ceiling on retained records. The log must not become the leak it is
  /// investigating: a repo that degrades and recovers in a loop would
  /// otherwise grow one record per transition for the life of the session.
  static const int maxRecords = 200;

  final _records = <WatchTransitionRecord>[];

  /// Oldest first.
  List<WatchTransitionRecord> get records => List.unmodifiable(_records);

  void add(WatchTransitionRecord record) {
    _records.add(record);
    // Drop from the front rather than clearing: the oldest transitions are the
    // least useful (a degradation is diagnosed from what led into it, and the
    // capture is taken while it is happening), but clearing wholesale would
    // lose the run-up to the very event being investigated.
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
    }
  }

  void clear() => _records.clear();

  /// One line answering *"why is this repo polling?"* from the recorded
  /// history, for the output log a maintainer is already reading.
  ///
  /// The degradation itself is not the useful part — that it happened is
  /// already visible as a grey watch indicator. What is useful is the run-up:
  /// the cause the engine collapsed to `WatchUnavailable`, how much restart
  /// budget was spent getting there, and how many watcher processes the
  /// connection was holding at that moment.
  String? get degradationSummary {
    final at = _records.lastIndexWhere(
      (r) => r.kind == WatchTransition.degradedToPolling,
    );
    if (at < 0) return null;
    final d = _records[at];
    // The transitions that led into it, most recent last.
    final runUp = _records
        .sublist(at >= 4 ? at - 4 : 0, at)
        .map((r) => '${r.kind.name}(${r.cause})')
        .join(' -> ');
    final tail = runUp.isEmpty ? '' : '  after: $runUp';
    return 'polling ${d.repoPath} — ${d.cause}; '
        'watchers held ${d.liveWatchers}, restarts spent ${d.restarts}$tail';
  }
}

/// Process-wide transition logs, keyed by repository path.
class WatchDiagnostics {
  final _logs = <String, WatchTransitionLog>{};

  WatchTransitionLog forRepo(String repoPath) =>
      _logs.putIfAbsent(repoPath, WatchTransitionLog.new);

  /// Repos with any recorded history.
  Iterable<String> get repoPaths => _logs.keys;

  void clear() => _logs.clear();
}

/// The shared log every watcher engine records into.
final WatchDiagnostics watchDiagnostics = WatchDiagnostics();
