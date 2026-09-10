import 'dart:async';

/// Decides when a bounded watch must re-arm, and debounces it.
///
/// A bounded surface is derived from the index, so a git-state change can mean
/// there are now tracked files in directories this arming does not cover. The
/// answer is to recompute and re-arm — once, after the burst: a single
/// `git add` writes the index several times (0022 H5).
///
/// This logic was written twice, line for line, in the remote and local
/// services, with its debounce constant declared twice (MADR 0045 F6).
final class SurfaceRearmPolicy {
  SurfaceRearmPolicy({required this.debounce});

  /// How long the burst must go quiet before re-arming.
  final Duration debounce;

  Timer? _timer;

  /// Considers one changed [path]. Re-arms only for a [bounded] surface and only
  /// for a git-state path (`.git/…`); a work-tree edit cannot change which
  /// directories are tracked.
  void onPath(
    String path, {
    required bool bounded,
    required void Function() rearm,
    required bool Function() cancelled,
  }) {
    if (!bounded || !path.startsWith('.git/')) return;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      if (cancelled()) return;
      rearm();
    });
  }

  /// Drops a pending re-arm. Called by every teardown.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
