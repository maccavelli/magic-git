import 'security_scoped_bookmark.dart';

/// Process-global reference count over macOS security-scoped access, keyed by
/// resolved path.
///
/// The native grant (`MainFlutterWindow.activeScopedURLs`) is **single-slot,
/// last-wins per path**: starting access for a path that's already active
/// replaces the prior URL, and one `stopAccessingBookmark` ends it. That's
/// correct for a single session, but two tabs open on the SAME local folder
/// would step on each other — when the first tab disconnects it would call
/// `stopAccessing` and pull the shared grant out from under the second, whose
/// `git`/`glab` children then lose the sandbox grant mid-session.
///
/// This registry brackets the native start/stop with an app-level refcount so
/// access is started on the FIRST acquire for a path and released only on the
/// LAST. There is one main window (secondary windows run in their own engines
/// and don't open local sessions), so a single process-global instance is the
/// right scope — every tab's [ConnectionController] and the connect flow share
/// [instance].
class ScopedAccess {
  ScopedAccess({
    Future<String?> Function(String bookmarkData)? startAccessing,
    Future<void> Function(String path)? stopAccessing,
  }) : _start = startAccessing ?? SecurityScopedBookmark.startAccessing,
       _stop = stopAccessing ?? SecurityScopedBookmark.stopAccessing;

  /// The shared registry used across the app. Tests construct their own
  /// instance with injected start/stop instead of touching this.
  static final ScopedAccess instance = ScopedAccess();

  final Future<String?> Function(String) _start;
  final Future<void> Function(String) _stop;

  /// path → number of open sessions currently holding access to it.
  final Map<String, int> _counts = {};

  /// Resolves [bookmarkData] and ensures security-scoped access is held,
  /// incrementing the refcount for the resolved path. Returns the resolved
  /// absolute path, or null if resolution/access failed (caller re-prompts).
  /// The underlying native start is naturally idempotent (last-wins keeps one
  /// URL active per path), so a second acquire just bumps the count.
  Future<String?> acquire(String bookmarkData) async {
    final path = await _start(bookmarkData);
    if (path == null) return null;
    _counts[path] = (_counts[path] ?? 0) + 1;
    return path;
  }

  /// Releases one hold on [path]. Native access is ended only when the last
  /// holder releases. A path this registry never tracked (an ad-hoc,
  /// picker-granted folder with no bookmark) is a no-op — it was never started
  /// through here, so there's nothing to balance.
  Future<void> release(String path) async {
    final n = _counts[path];
    if (n == null) return;
    if (n <= 1) {
      _counts.remove(path);
      await _stop(path);
    } else {
      _counts[path] = n - 1;
    }
  }

  /// The current number of holders on [path] — for tests/diagnostics.
  int holdCount(String path) => _counts[path] ?? 0;
}
