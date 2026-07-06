/// How the remote repository watcher is currently refreshing status.
enum WatchMode {
  /// Live filesystem events via fswatch or inotifywait on the remote host.
  eventDriven,

  /// fswatch unavailable or restart budget exhausted — periodic polling instead.
  polling,

  /// Watcher could not be started and polling has not yet armed.
  stopped,
}

/// A coalesced "repo may have changed" tick plus the active watch mode so the
/// UI can distinguish live events from polling fallback.
class RepoWatchEvent {
  final DateTime at;
  final WatchMode mode;

  const RepoWatchEvent({required this.at, required this.mode});
}
