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

/// Which part of a repository a watch tick touched.
///
/// [unknown] is not "nothing": a polling tick, a watcher restart, or a burst
/// too large to enumerate all carry no path information, and the only safe
/// reading of that is "anything may have changed" — the same contract
/// [RepoWatchEvent.paths] already documents.
enum GitArea { gitIndex, refs, stash, reflog, worktree, worktrees, unknown }

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

  /// Which parts of the repository this tick touched.
  ///
  /// The watcher already knows what moved; nothing consumed it for
  /// invalidation scope, so a change under `refs/` re-read the working tree and
  /// a file edit re-read the log (0025 F2). An unclassified path under `.git`
  /// yields [GitArea.unknown] deliberately — the conservative answer is the
  /// safe one, and the same one the paths contract already documents.
  Set<GitArea> get touchedAreas {
    if (paths.isEmpty) return const {GitArea.unknown};
    return {for (final p in paths) _areaFor(p)};
  }

  static GitArea _areaFor(String path) {
    final String rest;
    if (path.startsWith('.git/')) {
      rest = path.substring(5);
    } else {
      final i = path.indexOf('/.git/');
      if (i < 0) return GitArea.worktree;
      rest = path.substring(i + 6);
    }
    if (rest == 'index') return GitArea.gitIndex;
    if (rest == 'stash' || rest.startsWith('refs/stash')) return GitArea.stash;
    if (rest.startsWith('logs/')) return GitArea.reflog;
    if (rest.startsWith('worktrees/')) return GitArea.worktrees;
    if (rest.startsWith('refs/') ||
        rest == 'HEAD' ||
        rest == 'ORIG_HEAD' ||
        rest == 'MERGE_HEAD' ||
        rest == 'FETCH_HEAD' ||
        rest == 'CHERRY_PICK_HEAD' ||
        rest == 'REBASE_HEAD' ||
        rest == 'packed-refs') {
      return GitArea.refs;
    }
    return GitArea.unknown;
  }

  RepoWatchEvent withPaths(Set<String> paths) =>
      RepoWatchEvent(at: at, mode: mode, paths: paths);
}
