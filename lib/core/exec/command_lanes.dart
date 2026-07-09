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

class _Job {
  final ExecLane lane;
  final Future<void> Function() body;
  _Job(this.lane, this.body);
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
class CommandLaneScheduler {
  CommandLaneScheduler({this.maxConcurrentReads = 6});

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
  Future<T> run<T>(ExecLane lane, Future<T> Function() body) {
    final completer = Completer<T>();
    _queue.add(
      _Job(lane, () async {
        try {
          completer.complete(await body());
        } catch (e, st) {
          completer.completeError(e, st);
        }
      }),
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
    // Microtask deferral: see the class doc — a job must never begin inside
    // the caller's own synchronous enqueue frame. Errors were already routed
    // to the job's completer inside `run`, so this future cannot fail.
    Future<void>.microtask(job.body).whenComplete(() {
      switch (job.lane) {
        case ExecLane.read:
          _activeReads--;
        case ExecLane.sync:
          _activeSyncs--;
        case ExecLane.exclusive:
          _activeExclusives--;
      }
      _pump();
    });
  }
}
