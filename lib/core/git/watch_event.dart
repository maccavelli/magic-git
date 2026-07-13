/// How the repository watcher is currently refreshing status.
enum WatchMode {
  /// Live filesystem events via fswatch or inotifywait on the remote host, or
  /// `Directory.watch()` locally.
  eventDriven,

  /// fswatch unavailable or restart budget exhausted — periodic polling instead.
  polling,

  /// Watcher could not be started and polling has not yet armed.
  stopped,
}

/// A coalesced "repo may have changed" tick: the active watch mode, plus
/// **which paths** the burst touched.
///
/// The paths are what let a change be answered in proportion to it. A tick
/// without them can only say "something, somewhere, moved" — so everything
/// derived from the working tree (every cached diff, blame, conflict and
/// untracked preview, for every file) has to be discarded on the chance that it
/// was the one that changed. That is ruinous twice over: a build writing into
/// an ignored directory re-fetches the world several times a second, and when
/// the discard lands on a fetch that hasn't returned yet it restarts it from
/// nothing — which is how a diff pane ends up spinning forever without ever
/// showing a diff.
class RepoWatchEvent {
  final DateTime at;
  final WatchMode mode;

  /// Repo-root-relative, forward-slash paths seen in this burst.
  ///
  /// **Empty means "unknown", not "nothing".** A polling tick, or the tick a
  /// watcher emits when it (re)starts, carries no path information, and
  /// consumers must treat it as "anything may have changed". Only an
  /// event-driven tick with a non-empty set is a precise claim about what moved.
  final Set<String> paths;

  const RepoWatchEvent({
    required this.at,
    required this.mode,
    this.paths = const {},
  });

  /// Whether this tick names what changed, so consumers may act on just those
  /// paths rather than assuming the worst.
  bool get isScoped => paths.isNotEmpty;

  /// Whether git's own state moved — the index, HEAD, a ref.
  ///
  /// This cannot be attributed to any one file, and it is not path-scoped even
  /// though it arrives as a path. An `git add -p` run in a terminal rewrites the
  /// index while leaving both the file on disk and its porcelain record exactly
  /// as they were, and yet the *staged* diff of that file is now different. So a
  /// tick touching git's state means "any file's relationship to the index or to
  /// HEAD may have changed", and the only safe scope for it is the whole repo.
  ///
  /// Rare by nature — it takes a real git operation, not a build — so paying
  /// repo-wide invalidation for it costs nothing in the case that matters.
  bool get touchesGitState =>
      paths.any((p) => p == '.git' || p.startsWith('.git/'));

  RepoWatchEvent withPaths(Set<String> paths) =>
      RepoWatchEvent(at: at, mode: mode, paths: paths);
}
