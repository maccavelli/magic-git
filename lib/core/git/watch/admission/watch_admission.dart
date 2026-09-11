import 'host_watcher_budget.dart';
import 'repo_exclusion.dart';

/// Decides whether a watcher may arm: exclusion within the session, then the
/// host's budget.
///
/// **Exclusion first.** A caller waiting for its predecessor's lock must not sit
/// on a budget slot while it waits — on a degraded session the budget is one
/// slot, and holding it through a teardown would refuse every other repository
/// on the host for no reason.
final class WatchAdmission {
  WatchAdmission({required this.budget});

  /// The host budget, shared with every other session on this process.
  final HostWatcherBudget budget;

  /// This session's exclusion. One per admission, which is one per session.
  final RepoExclusion exclusion = RepoExclusion();

  /// Waits for the repository lock, then reserves a slot on [host].
  Future<AdmissionResult> admit({
    required String host,
    required int capacity,
    required String lockKey,
    required Duration grace,
    required Future<void> cancelled,
  }) async {
    final hold = await exclusion.acquire(
      lockKey,
      grace: grace,
      cancelled: cancelled,
    );
    if (hold == null) return const AdmissionCancelled();
    final slot = budget.tryReserve(host, capacity: capacity);
    if (slot == null) {
      // Refused: nothing will arm, so nothing may keep the lock.
      hold.release();
      return RefusedCeiling(live: budget.liveFor(host), capacity: capacity);
    }
    return Admitted(AdmissionTicket._(slot, hold));
  }
}

/// What [WatchAdmission.admit] decided.
sealed class AdmissionResult {
  const AdmissionResult();
}

/// Admitted: the caller holds a slot and the repository lock.
final class Admitted extends AdmissionResult {
  const Admitted(this.ticket);
  final AdmissionTicket ticket;
}

/// The host's watcher ceiling is spent.
final class RefusedCeiling extends AdmissionResult {
  const RefusedCeiling({required this.live, required this.capacity});
  final int live;
  final int capacity;
}

/// The caller left while waiting for the lock.
final class AdmissionCancelled extends AdmissionResult {
  const AdmissionCancelled();
}

/// A slot and a lock, released separately because they are released at
/// different moments: the slot first, so a waiting repository on the host can
/// take it at once; the lock last, only once the host has given its own back.
final class AdmissionTicket {
  AdmissionTicket._(this._slot, this._hold);

  final BudgetSlot _slot;
  final ExclusionHold _hold;

  /// Whether the lock was taken because the grace ran out.
  bool get graceExpired => _hold.graceExpired;

  /// Gives the budget slot back. Idempotent.
  void releaseBudget() => _slot.release();

  /// Gives the repository lock back. Idempotent.
  void releaseExclusion() => _hold.release();

  /// Both, slot first. Idempotent.
  void releaseAll() {
    releaseBudget();
    releaseExclusion();
  }
}
