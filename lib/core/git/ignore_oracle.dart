import 'git_service.dart';

/// Answers "does git ignore this path?" for the repository watcher — from
/// memory, almost always without asking git at all.
///
/// The watcher's whole problem is that a build writes thousands of files git
/// does not care about, and each one, taken at face value, means "the working
/// tree changed: throw away every cached diff and re-read the repo". Asking
/// `git check-ignore` per event would replace that with a round trip per event,
/// which over SSH is no better.
///
/// What makes this cheap is a rule git guarantees: **a file underneath an
/// excluded directory cannot be re-included.** So a directory's verdict is
/// final for everything beneath it, at any depth — `build/` is decided *once*,
/// and every artifact a build subsequently drops in there is answered from a
/// map lookup on an ancestor, forever, with no git involved. The paths that do
/// need asking (files in directories git tracks) are asked for in one batch.
///
/// Decisions are cached until an ignore *source* changes ([forgetRepo], driven
/// by a `.gitignore` edit), because that is the only thing that can change an
/// answer.
class GitIgnoreOracle {
  GitIgnoreOracle(this._git);

  final GitService _git;

  /// repoPath → directory → ignored. Small and stable: one entry per directory
  /// a watched event has ever named.
  final _dirs = <String, Map<String, bool>>{};

  /// repoPath → file → ignored. Only files whose ancestors are all *un*ignored
  /// ever land here — an ignored directory answers for its contents without
  /// them being remembered individually, which is what keeps this bounded while
  /// a build churns.
  final _files = <String, Map<String, bool>>{};

  /// Beyond this many individually-remembered files in one repo, the map is
  /// cleared rather than grown without limit. Losing a decision only costs the
  /// round trip to make it again; keeping every path a long session ever saw
  /// would not.
  static const _maxFilesPerRepo = 4096;

  /// Paths that *change the answers*: editing one invalidates every decision
  /// made from it. `.gitignore` at any depth, plus the repo-local exclude file.
  static bool isIgnoreSource(String path) =>
      path == '.gitignore' ||
      path.endsWith('/.gitignore') ||
      path == '.git/info/exclude';

  /// Drops every cached decision for [repoPath]. Called when an ignore source
  /// changes, and when a repo's state is torn down (disconnect, repo switch).
  void forgetRepo(String repoPath) {
    _dirs.remove(repoPath);
    _files.remove(repoPath);
  }

  void clear() {
    _dirs.clear();
    _files.clear();
  }

  /// The subset of [paths] that git does **not** ignore — i.e. the ones a
  /// change to which could actually mean something.
  ///
  /// Paths under `.git/` are never consulted: they are git's own state (index,
  /// HEAD, refs), always meaningful, and `check-ignore` has no opinion on them.
  /// Callers are expected to have filtered the noisy ones already
  /// ([shouldTriggerWatch]).
  Future<Set<String>> visible(String repoPath, Set<String> paths) async {
    if (paths.isEmpty) return const {};

    final dirs = _dirs.putIfAbsent(repoPath, () => {});
    final files = _files.putIfAbsent(repoPath, () => {});

    final visible = <String>{};
    // Paths with no cached verdict, and the novel ancestor directories they
    // depend on — both resolved in a single batched call below.
    final unknownPaths = <String>{};
    final unknownDirs = <String>{};

    bool? cachedVerdict(String path) {
      for (final dir in _ancestorsOf(path)) {
        final verdict = dirs[dir];
        if (verdict == true) return true; // an excluded dir is final
        if (verdict == null) return null; // undecided: must ask
      }
      return files[path];
    }

    for (final path in paths) {
      if (_isGitInternal(path)) {
        visible.add(path);
        continue;
      }
      final verdict = cachedVerdict(path);
      if (verdict == false) {
        visible.add(path);
      } else if (verdict == null) {
        unknownPaths.add(path);
        for (final dir in _ancestorsOf(path)) {
          if (!dirs.containsKey(dir)) unknownDirs.add(dir);
        }
      }
      // verdict == true → ignored → simply not visible.
    }

    if (unknownPaths.isEmpty) return visible;

    // One round trip for every open question in this burst: the directories
    // (whose verdicts will answer for whole subtrees from here on) and the
    // files themselves.
    final query = [...unknownDirs, ...unknownPaths];
    final ignored = await _git.checkIgnore(repoPath, query);

    for (final dir in unknownDirs) {
      dirs[dir] = ignored.contains(dir);
    }
    if (files.length > _maxFilesPerRepo) files.clear();
    for (final path in unknownPaths) {
      final isIgnored =
          ignored.contains(path) ||
          _ancestorsOf(path).any((d) => dirs[d] == true);
      files[path] = isIgnored;
      if (!isIgnored) visible.add(path);
    }
    return visible;
  }

  /// `.git` itself and everything under it.
  static bool _isGitInternal(String path) =>
      path == '.git' || path.startsWith('.git/');

  /// Every directory containing [path], outermost first — `a/b/c.txt` yields
  /// `a`, then `a/b`. Outermost-first matters: the shallowest excluded
  /// directory settles the question, and nothing below it can reopen it.
  static List<String> _ancestorsOf(String path) {
    final parts = path.split('/');
    if (parts.length < 2) return const [];
    return [
      for (var i = 1; i < parts.length; i++) parts.take(i).join('/'),
    ];
  }
}
