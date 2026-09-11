import 'dart:async';

/// One live watcher per repository lock, per session.
///
/// The host refuses a second watcher on a repository with its `mkdir` lock, and
/// that refusal must only ever mean ANOTHER session (MADR 0043 F1). Inside one
/// session the next watcher therefore waits for the previous one to give the
/// lock back before it asks the host — which MADR 0043's shared watcher did by
/// sharing, and what sharing got wrong: a handle that could be overwritten held
/// the watcher's lifetime (0043.1), and identity left out the parameters
/// (MADR 0045 F1, F2). This owns exclusion and nothing else.
///
/// Keyed by the lock directory the host script claims, so the two can never
/// disagree about what "the same repository" means.
final class RepoExclusion {
  final Map<String, ExclusionHold> _holds = {};

  /// Whether a hold is installed for [lockKey].
  bool isHeld(String lockKey) => _holds.containsKey(lockKey);

  /// Waits until no other hold exists for [lockKey], then installs one.
  ///
  /// Returns null, and installs nothing, if [cancelled] completes first: a
  /// caller who left while waiting must not take the lock from one who arrives
  /// after.
  ///
  /// Bounded by [grace], measured from this call. On expiry it proceeds anyway
  /// and says so on the hold: a teardown that never settles degrades to the old
  /// race rather than leaving the repository unwatchable for the session.
  Future<ExclusionHold?> acquire(
    String lockKey, {
    required Duration grace,
    required Future<void> cancelled,
  }) async {
    var isCancelled = false;
    unawaited(cancelled.then((_) => isCancelled = true));
    final expired = Completer<void>();
    final timer = Timer(grace, () {
      if (!expired.isCompleted) expired.complete();
    });
    var graceExpired = false;
    try {
      // A LOOP, not one wait: several waiters wake on one release, the first to
      // run installs its hold, and the rest must wait on that one in turn.
      for (
        var current = _holds[lockKey];
        current != null;
        current = _holds[lockKey]
      ) {
        final wake = await Future.any<_Wake>([
          current.released.then((_) => _Wake.released),
          cancelled.then((_) => _Wake.cancelled),
          expired.future.then((_) => _Wake.expired),
        ]);
        if (wake == _Wake.cancelled) return null;
        if (wake == _Wake.expired) {
          graceExpired = true;
          break;
        }
      }
      // Cancelled in the same turn the predecessor released: the release won
      // the race, but nobody is left to hold the lock for.
      if (isCancelled) return null;
      final hold = ExclusionHold._(this, lockKey, graceExpired: graceExpired);
      _holds[lockKey] = hold;
      return hold;
    } finally {
      timer.cancel();
    }
  }
}

enum _Wake { released, cancelled, expired }

/// The right to arm one watcher on one repository lock.
final class ExclusionHold {
  ExclusionHold._(this._owner, this.lockKey, {required this.graceExpired});

  final RepoExclusion _owner;

  /// The lock directory this hold covers.
  final String lockKey;

  /// Whether this hold was installed because the grace ran out rather than
  /// because its predecessor released.
  final bool graceExpired;

  final Completer<void> _released = Completer<void>();

  /// Completes when [release] runs.
  Future<void> get released => _released.future;

  /// Whether [release] has run.
  bool get isReleased => _released.isCompleted;

  /// Gives the lock back to the session. Idempotent.
  ///
  /// Removes the key only while this is still the installed hold: after a grace
  /// expiry a newer hold has replaced this one, and a late release from the
  /// wedged predecessor must not open the door beside it.
  void release() {
    if (_released.isCompleted) return;
    if (identical(_owner._holds[lockKey], this)) _owner._holds.remove(lockKey);
    _released.complete();
  }
}
