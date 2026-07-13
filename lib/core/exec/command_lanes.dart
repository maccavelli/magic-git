import 'dart:async';

/// Which scheduling lane a command runs in. Chosen by the *call site* (the
/// service layer knows what each git invocation touches), enforced by
/// [CommandLaneScheduler] inside each executor.
///
/// The old design serialized every command onto one global chain to protect
/// `.git/index.lock` — but that made a single slow network op (a `git fetch`
/// with a 3-minute timeout) head-of-line-block every status/diff/blame read in
/// the app. The lock only ever matters for commands that *write* the index or
/// working tree; reads here always run with `GIT_OPTIONAL_LOCKS=0` and never
/// take it, and SSH multiplexes channels natively, so reads can safely overlap
/// both each other and a fetch.
enum ExecLane {
  /// A read-only command (status, log, diff, blame, `cat`, CLI list calls).
  /// Runs concurrently with other reads and with [sync] commands, bounded by
  /// [CommandLaneScheduler.maxConcurrentReads].
  read,

  /// A remote-sync command (`git fetch`, `git push`) or a forge-CLI mutation
  /// (approve/merge a PR): touches refs or the network but never the index or
  /// working tree, so it is safe to overlap with reads — but only one runs at
  /// a time, so two fetches can never race each other on ref locks.
  sync,

  /// An index/worktree mutation (stage, commit, checkout, pull, rebase, …).
  /// Runs strictly alone: it waits for every in-flight read/sync to finish,
  /// nothing else starts until it completes, and — because it acts as a FIFO
  /// barrier — commands enqueued after it never jump ahead of it.
  exclusive,
}

/// A job held a lane slot past its deadline and the scheduler took the slot back.
///
/// This is a **backstop**, and seeing one means something below the scheduler is
/// broken — every executor already bounds its own command with `.timeout()` and
/// kills the process, so a body that is still unsettled a further
/// [CommandLaneScheduler.watchdogMargin] later is not a slow command, it is a
/// command that lost its way. The alternative to reclaiming the slot is worse
/// than any error: see [CommandLaneScheduler._start].
class CommandLaneOverrun implements Exception {
  const CommandLaneOverrun(this.lane, this.deadline);

  final ExecLane lane;
  final Duration deadline;

  @override
  String toString() =>
      'A ${lane.name} command did not finish or fail within '
      '${deadline.inSeconds}s and its slot was reclaimed. This is a bug in the '
      'command executor, not a slow command — it should have timed out on its '
      'own well before this.';
}

class _Job {
  _Job(this.lane, this.deadline, this.body, this.onOverrun);

  final ExecLane lane;

  /// How long this job may hold its slot once it *starts*. Timed from the start,
  /// not from enqueue: a job queued behind a five-minute commit has not overrun
  /// anything, it simply hasn't had its turn.
  final Duration deadline;

  final Future<void> Function() body;

  /// Fails this job's caller when the deadline passes with the body unsettled.
  final void Function() onOverrun;
}

/// Lane-aware command scheduler shared by both executors (SSH and local).
///
/// Semantics:
/// - [ExecLane.read] jobs run concurrently, up to [maxConcurrentReads].
/// - [ExecLane.sync] jobs run one-at-a-time, concurrently with reads.
/// - [ExecLane.exclusive] jobs run strictly alone and act as a barrier:
///   everything enqueued before one completes first, and nothing enqueued
///   after it starts until it has finished. Two exclusives therefore still
///   run in strict FIFO order — the exact serialization guarantee the old
///   single-chain queue provided for mutations.
/// - Jobs never start synchronously inside the enqueue call: each body is
///   deferred to a microtask, so state changed immediately after enqueuing
///   (e.g. a generation bump from a disconnect) is observed by the job.
/// - A job's error propagates to its own caller only; the scheduler itself
///   never wedges on a failed job.
/// - **A job cannot hold its slot forever.** See [watchdogMargin].
class CommandLaneScheduler {
  CommandLaneScheduler({this.maxConcurrentReads = 6});

  /// Grace period a job gets *beyond its own deadline* before the scheduler
  /// reclaims its slot.
  ///
  /// Everything here used to rest on an invariant the scheduler never checked:
  /// "a job body always settles". It happens to be true — both executors wrap
  /// their command in `.timeout()` and kill the process — but nothing enforced
  /// it, and the cost of it ever becoming false is out of all proportion to the
  /// bug that would cause it. A body that never settles never runs its
  /// `whenComplete`, so its slot is never given back; six of those and the read
  /// lane is gone, one on the exclusive lane and *every* command in the app
  /// queues behind it. Forever, silently, with no error raised anywhere — the
  /// app simply stops doing anything, and every pane waiting on a read spins.
  ///
  /// So the scheduler now enforces the invariant instead of assuming it. The
  /// margin is deliberately generous: this must never be the mechanism that ends
  /// a merely-slow command (the command's own timeout is), only the one that
  /// catches a command that has stopped existing.
  static const Duration watchdogMargin = Duration(seconds: 30);

  /// Ceiling on concurrently running [ExecLane.read] jobs. High enough that a
  /// couple of slow forge-CLI calls can't crowd out interactive git reads;
  /// low enough not to swamp a remote host with parallel processes.
  final int maxConcurrentReads;

  final _queue = <_Job>[];
  int _activeReads = 0;
  int _activeSyncs = 0;
  int _activeExclusives = 0;

  /// Currently running jobs — for tests/diagnostics.
  int get activeReads => _activeReads;
  int get activeSyncs => _activeSyncs;
  int get activeExclusives => _activeExclusives;

  /// Number of jobs waiting to start — for tests/diagnostics.
  int get queued => _queue.length;

  /// Enqueues [body] on [lane] and completes with its result.
  ///
  /// [deadline] is how long [body] may hold its slot once it starts — the
  /// command's own timeout plus [watchdogMargin]. It is a backstop, not the
  /// command's timeout: see [watchdogMargin].
  Future<T> run<T>(
    ExecLane lane,
    Future<T> Function() body, {
    required Duration deadline,
  }) {
    final completer = Completer<T>();
    _queue.add(
      _Job(
        lane,
        deadline,
        () async {
          try {
            final result = await body();
            // May already be completed by the watchdog, if the body came back
            // from the dead after its slot was reclaimed. First answer wins.
            if (!completer.isCompleted) completer.complete(result);
          } catch (e, st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          }
        },
        () {
          if (!completer.isCompleted) {
            completer.completeError(
              CommandLaneOverrun(lane, deadline),
              StackTrace.current,
            );
          }
        },
      ),
    );
    _pump();
    return completer.future;
  }

  void _pump() {
    var i = 0;
    while (i < _queue.length) {
      final job = _queue[i];
      switch (job.lane) {
        case ExecLane.exclusive:
          // Starts only from the very head of the queue with nothing active;
          // and while it waits there, nothing behind it may start either
          // (the barrier that keeps mutations strictly ordered).
          if (i == 0 &&
              _activeReads == 0 &&
              _activeSyncs == 0 &&
              _activeExclusives == 0) {
            _start(_queue.removeAt(0));
            continue;
          }
          return;
        case ExecLane.read:
          if (_activeExclusives == 0 && _activeReads < maxConcurrentReads) {
            _start(_queue.removeAt(i));
            continue;
          }
          // Pool full — a later sync may still be startable, so keep scanning
          // rather than blocking the whole queue on it.
          i++;
        case ExecLane.sync:
          if (_activeExclusives == 0 && _activeSyncs == 0) {
            _start(_queue.removeAt(i));
            continue;
          }
          i++;
      }
    }
  }

  void _start(_Job job) {
    switch (job.lane) {
      case ExecLane.read:
        _activeReads++;
      case ExecLane.sync:
        _activeSyncs++;
      case ExecLane.exclusive:
        _activeExclusives++;
    }

    // The slot is given back exactly once, by whichever comes first: the body
    // settling, or the watchdog giving up on it.
    var released = false;
    void release() {
      if (released) return;
      released = true;
      switch (job.lane) {
        case ExecLane.read:
          _activeReads--;
        case ExecLane.sync:
          _activeSyncs--;
        case ExecLane.exclusive:
          _activeExclusives--;
      }
      _pump();
    }

    // Reclaiming an *exclusive* slot from a body that hasn't settled is the one
    // uncomfortable case: in principle it lets the next mutation start while the
    // last one is still out there, and two writers race on `.git/index.lock`.
    // It is still the right call. Both executors already kill the process when
    // their own timeout fires, so a body still unsettled a further
    // [watchdogMargin] beyond that is not a running `git` — it is a future that
    // will never complete, and there is nothing to race with. And if the
    // impossible happened anyway, git's own lock turns it into a legible error
    // on one command, where holding the slot turns it into an app that never
    // runs another command as long as it is open.
    final watchdog = Timer(job.deadline, () {
      job.onOverrun();
      release();
    });

    // Microtask deferral: see the class doc — a job must never begin inside
    // the caller's own synchronous enqueue frame. Errors were already routed
    // to the job's completer inside `run`, so this future cannot fail.
    Future<void>.microtask(job.body).whenComplete(() {
      watchdog.cancel();
      release();
    });
  }
}
