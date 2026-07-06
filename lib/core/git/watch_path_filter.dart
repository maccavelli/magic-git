/// Whether a changed path (relative to the repo root, forward-slash
/// separated) should trigger a status refresh. Shared by [RemoteWatchService]
/// (fed by fswatch/inotifywait output) and `LocalWatchService` (fed by
/// `dart:io`'s `Directory.watch()`), so both backends suppress the same
/// noisy/irrelevant paths.
///
/// Deliberately does NOT exclude `.git/index`/`HEAD`/`refs/**`: those are
/// exactly the paths any git invocation (this app's own, or another process
/// on the same host/filesystem) touches, and detecting *that* is the
/// watcher's whole purpose. Time-windowed suppression of this app's own
/// redundant refresh lives in `OwnMutationTracker` instead — see
/// `app_providers.dart`.
bool shouldTriggerWatch(String path) {
  if (path.isEmpty) return false;
  // The `.git` directory reported as a directory-granularity event (path is
  // exactly `.git` or `…/.git`, no inner component). macOS FSEvents surfaces
  // these to the local backend where inotify/fswatch never do; the meaningful
  // git-state changes inside it (`index`, `HEAD`, `refs/**`) arrive as their
  // own specific paths and are handled below, so the bare directory event is
  // pure noise — letting it through re-refreshes on every git-op lock churn,
  // defeating the `.lock` suppression.
  if (path == '.git' || path.endsWith('/.git')) return false;
  if (path.contains('/.git/') || path.startsWith('.git/')) {
    if (path.endsWith('.lock') ||
        path.contains('/objects/') ||
        path.contains('/logs/') ||
        path.contains('/fsmonitor--daemon/')) {
      return false;
    }
  }
  if (path.endsWith('.swp') ||
      path.endsWith('.swo') ||
      path.endsWith('.swn') ||
      path.endsWith('~') ||
      path.endsWith('/4913') ||
      path.contains('.goutputstream-')) {
    return false;
  }
  return true;
}
