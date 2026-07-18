import '../ssh/shell_escaper.dart';

/// Bounded watch surface for a **scoped work-tree repo** — the dotfiles pattern
/// where a single git-dir (e.g. `~/.home.git`) has its work tree set to a huge
/// directory (e.g. `$HOME`). A recursive watch of that work tree is a
/// non-starter: on a real bastion `$HOME` measured 257k directories against a
/// host `fs.inotify.max_user_watches` of 524k — one repo would claim ~half the
/// entire per-user inotify budget, take seconds and hundreds of MB of kernel
/// memory to arm, and drown the app in events from caches and build output it
/// can never act on.
///
/// The key simplification this mode is allowed to make (and the reason it is
/// gated behind an explicit repo-type toggle): such a repo runs with
/// `status.showUntrackedFiles=no`, so **untracked files do not matter**. The
/// only things that can change what the UI shows are:
///
///   1. an edit to a **tracked** working-tree file, and
///   2. a change to **git's own state** — the index, HEAD, or a ref.
///
/// So the watch surface collapses to a small, explicit set of directories,
/// watched **non-recursively**:
///
///   * the parent directory of every tracked file (from `git ls-files`), so a
///     content edit to any tracked dotfile fires — and nothing else in `$HOME`
///     does, and
///   * a few fixed points inside the git-dir: its root (`index`, `HEAD`,
///     `packed-refs`, `ORIG_HEAD`, `MERGE_HEAD`, lock files all live directly
///     here) and `refs/heads` (branch ref writes). Object writes land under
///     `objects/xx/…`, which a *non-recursive* git-dir-root watch never sees —
///     so a commit or gc floods nothing.
///
/// This is the same multi-root, path-remapping strategy `LocalWatchService`
/// already uses for a linked worktree (watch the worktree dir + the common git
/// dir, rewrite git-dir events to look like `.git/…`), specialized for a
/// tracked-only work tree.
class BoundedWatchSpec {
  /// Absolute git-dir (e.g. `/home/u/.home.git`). Trailing slash stripped.
  final String gitDir;

  /// Absolute work tree (e.g. `/home/u`). Trailing slash stripped.
  final String workTree;

  /// Absolute directories to watch **non-recursively** — the parent dirs of
  /// tracked files (deduped, sorted), plus the git-dir watch points. This is
  /// the complete inotify/fswatch surface for the repo.
  final List<String> watchDirs;

  const BoundedWatchSpec({
    required this.gitDir,
    required this.workTree,
    required this.watchDirs,
  });
}

String _stripTrailingSlash(String p) =>
    (p.length > 1 && p.endsWith('/')) ? p.substring(0, p.length - 1) : p;

/// POSIX dirname of a repo-relative, forward-slash path. `'a/b/c'` → `'a/b'`;
/// a bare filename (`'.bashrc'`) → `''` (meaning the work-tree root itself).
String _relDir(String relPath) {
  final i = relPath.lastIndexOf('/');
  return i < 0 ? '' : relPath.substring(0, i);
}

/// Computes the bounded watch surface for [gitDir] / [workTree] given the
/// repo's [trackedFiles] (the raw, work-tree-relative output of `git ls-files`,
/// forward-slash separated).
///
/// The result watches every tracked file's parent directory plus the git-dir
/// signal points — no more. [trackedFiles] whose directory can't be formed are
/// skipped; an empty list still yields the git-dir points so state changes are
/// seen even before anything is tracked.
BoundedWatchSpec computeBoundedWatchSpec({
  required String gitDir,
  required String workTree,
  required Iterable<String> trackedFiles,
}) {
  final gd = _stripTrailingSlash(gitDir);
  final wt = _stripTrailingSlash(workTree);

  // Git-dir signal points: the root (index, HEAD, ORIG_HEAD, MERGE_HEAD,
  // packed-refs, lock files) plus the loose-ref dirs for branch and tag writes.
  // `refs/heads`/`refs/tags` may not exist yet (fresh/tagless repo); the arming
  // layer existence-guards each path (see boundedInotifyScript) so a missing one
  // is skipped rather than aborting the watcher.
  final dirs = <String>{gd, '$gd/refs/heads', '$gd/refs/tags'};

  for (final f in trackedFiles) {
    final rel = f.trim();
    if (rel.isEmpty) continue;
    final d = _relDir(rel);
    dirs.add(d.isEmpty ? wt : '$wt/$d');
  }

  final sorted = dirs.toList()..sort();
  return BoundedWatchSpec(gitDir: gd, workTree: wt, watchDirs: sorted);
}

/// Rewrites an absolute watcher event path back to the repo-root-relative,
/// forward-slash shape every downstream consumer ([shouldTriggerWatch],
/// [RepoWatchEvent.touchesGitState]) expects, or null if it falls outside the
/// spec (which should not happen for events from [BoundedWatchSpec.watchDirs]).
///
/// git-dir events become `.git/…` — so `<gitDir>/index` reads as `.git/index`
/// and correctly sets `touchesGitState`, exactly as it would in an ordinary
/// repo. The git-dir is checked **first** because it lives *inside* the work
/// tree (`~/.home.git` ⊂ `$HOME`), so a work-tree prefix test would otherwise
/// swallow it.
String? relativizeBoundedEvent(String absolutePath, BoundedWatchSpec spec) {
  if (absolutePath == spec.gitDir) return '.git';
  if (absolutePath.startsWith('${spec.gitDir}/')) {
    return '.git/${absolutePath.substring(spec.gitDir.length + 1)}';
  }
  if (absolutePath == spec.workTree) return '';
  if (absolutePath.startsWith('${spec.workTree}/')) {
    return absolutePath.substring(spec.workTree.length + 1);
  }
  return null;
}

/// Shell script (for `sh -c`) that arms `inotifywait` over exactly [watchDirs],
/// **non-recursively** (no `-r`), line-buffered via `stdbuf` when available so
/// each event flushes immediately over the pipe (same reasoning as the
/// recursive path). Each directory is shell-escaped and existence-guarded, so a
/// path that does not yet exist (empty-repo `refs/heads`) is silently skipped
/// rather than aborting the whole watcher.
///
/// Emits absolute paths (`%w%f` over absolute watch dirs) for
/// [relativizeBoundedEvent] to remap. Uses `exec` so a channel-close signal
/// reaches inotifywait itself, not a surviving shell wrapper.
String boundedInotifyScript(List<String> watchDirs) {
  final joined = watchDirs.map(ShellEscaper.escape).join(' ');
  const fmt = '-m -e modify,create,delete,move --format %w%f';
  // Build the existence-filtered positional list once, then exec inotifywait on
  // it. `set --` re-quotes safely; the loop drops any missing path.
  return 'set -- $joined; '
      'for d; do [ -e "\$d" ] && set -- "\$@" "\$d"; shift; done; '
      '[ "\$#" -gt 0 ] || exit 0; '
      'if command -v stdbuf >/dev/null 2>&1; then '
      'exec stdbuf -oL inotifywait $fmt "\$@"; '
      'else exec inotifywait $fmt "\$@"; fi';
}

/// fswatch equivalent of [boundedInotifyScript]: watch exactly [watchDirs].
/// fswatch is non-recursive unless `-r` is passed, so omitting it bounds the
/// surface to the listed directories. NUL-delimited (`-0`) like the recursive
/// path.
List<String> boundedFswatchArgs(List<String> watchDirs) => [
  'fswatch',
  '-0',
  '--latency',
  '0.5',
  ...watchDirs,
];
