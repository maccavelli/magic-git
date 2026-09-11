import 'dart:async';

/// The watcher slots each host allows, shared by every session in this process.
///
/// Scoped by INJECTION, never by a static. The budget belongs to the host, so
/// every tab's session on one host must count against one number — but a
/// process-wide static also joined every test, every container and every
/// service instance into that number, and needed a test-only reset seam to
/// survive it (MADR 0045 F5). Production hands one instance to every tab
/// container; a test builds its own.
///
/// Keyed by host because the process holds several sessions at once, and a
/// global counter let whichever tab armed first starve a host that had spent
/// nothing (MADR 0039 F4).
final class HostWatcherBudget {
  final Map<String, int> _live = {};

  /// Announces the host whose slot was just released, so a repository refused
  /// by the ceiling re-arms at once instead of polling until its recovery timer
  /// fires (0028 H2). Broadcast and never closed: it lives exactly as long as
  /// the counter it reports on.
  // ignore: close_sinks
  final StreamController<String> _released =
      StreamController<String>.broadcast();

  /// Reserves one slot on [host], or returns null when [capacity] is spent.
  ///
  /// Synchronous, so the check and the reservation cannot be separated by an
  /// arm that passed the same check a moment earlier (0028).
  BudgetSlot? tryReserve(String host, {required int capacity}) {
    final live = liveFor(host);
    if (live >= capacity) return null;
    _live[host] = live + 1;
    return BudgetSlot._(this, host);
  }

  /// Slots held on [host].
  int liveFor(String host) => _live[host] ?? 0;

  /// Slots held across every host — the figure a transition record carries.
  int get liveTotal => _live.values.fold(0, (sum, n) => sum + n);

  /// Releases on [host] alone. A release elsewhere must not wake a repository
  /// whose host is still full into an arm it can only lose.
  Stream<void> releases(String host) =>
      _released.stream.where((h) => h == host).map((_) {});

  void _release(String host) {
    final n = _live[host] ?? 0;
    if (n > 1) {
      _live[host] = n - 1;
    } else {
      // No zero entry left behind: it would read as a leaked watcher.
      _live.remove(host);
    }
    _released.add(host);
  }
}

/// One reserved slot.
final class BudgetSlot {
  BudgetSlot._(this._budget, this.host);

  final HostWatcherBudget _budget;

  /// The host that paid for this slot, resolved once at reservation. A session
  /// that moves host while its watcher is live must credit the host that
  /// reserved, not whichever one it is on now.
  final String host;

  var _released = false;

  /// Whether [release] has run.
  bool get isReleased => _released;

  /// Gives the slot back. Idempotent: the arm releases on each exit path and
  /// again from its catch-all, so a second call must be free.
  void release() {
    if (_released) return;
    _released = true;
    _budget._release(host);
  }
}
