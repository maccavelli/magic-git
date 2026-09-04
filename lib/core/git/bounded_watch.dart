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

/// Supplies a freshly-computed [BoundedWatchSpec].
///
/// The watch services take this rather than a spec value because the surface a
/// bounded watch should cover is not stable: every `git add` of a file in a
/// new directory widens it. Passing a value froze the surface for the life of
/// the stream (0022 H5); passing a supplier lets each arm — including a
/// deliberate re-arm — recompute it.
typedef BoundedWatchSpecSource = Future<BoundedWatchSpec> Function();

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
/// Exit status a bounded arming script uses for "none of the paths exist".
///
/// Distinct from 0 on purpose. It used to `exit 0`, which reads as a clean
/// watcher death: the lifecycle engine scheduled a restart, burned its budget
/// on three doomed retries, and only then degraded to polling — with nothing
/// said about why. A distinct status lets the caller map it straight to
/// [WatchUnavailable], which degrades to polling immediately *and* keeps
/// retrying on the recovery timer (0022 M6).
const int boundedWatchNoPathsExit = 97;

String boundedInotifyScript(List<String> watchDirs, {String? pidFile}) {
  final joined = watchDirs.map(ShellEscaper.escape).join(' ');
  const fmt = '-m -e modify,create,delete,move --format %w%f';
  // Build the existence-filtered positional list once, then exec inotifywait on
  // it. `set --` re-quotes safely; the loop drops any missing path.
  return 'set -- $joined; '
      'for d; do [ -e "\$d" ] && set -- "\$@" "\$d"; shift; done; '
      '[ "\$#" -gt 0 ] || exit $boundedWatchNoPathsExit; '
      '${_recordPid(pidFile)}'
      'if command -v stdbuf >/dev/null 2>&1; then '
      'exec stdbuf -oL inotifywait $fmt "\$@"; '
      'else exec inotifywait $fmt "\$@"; fi';
}

/// fswatch equivalent of [boundedInotifyScript]: watch exactly [watchDirs],
/// non-recursively (fswatch recurses only with `-r`), NUL-delimited (`-0`)
/// like the recursive path.
///
/// Runs through `sh -c` rather than as bare argv **because fswatch needs the
/// same existence guard inotifywait does**, for a different reason. inotifywait
/// aborts outright when handed a missing path; fswatch merely skips it — but a
/// skipped path is never retried, so a bounded watch armed before the first
/// `git tag` exists would never see `refs/tags` appear (0022 M6). Filtering
/// here keeps both backends honest about what they are actually watching, and
/// lets an all-missing set report [boundedWatchNoPathsExit] identically.
///
/// `exec` for the same reason as the inotify script: a channel close must reach
/// fswatch itself, not a surviving shell wrapper.
String boundedFswatchScript(List<String> watchDirs, {String? pidFile}) {
  final joined = watchDirs.map(ShellEscaper.escape).join(' ');
  return 'set -- $joined; '
      'for d; do [ -e "\$d" ] && set -- "\$@" "\$d"; shift; done; '
      '[ "\$#" -gt 0 ] || exit $boundedWatchNoPathsExit; '
      '${_recordPid(pidFile)}'
      'exec fswatch -0 --latency 0.5 "\$@"';
}

/// Records the arming shell's pid so a later sweep can find the watcher.
///
/// `$$` is the shell about to `exec`, so the pid written is the one the watcher
/// itself will run under — there is no wrapper to confuse a sweep. Empty when
/// no pid file is wanted, which keeps every existing caller's script identical.
String _recordPid(String? pidFile) => pidFile == null
    ? ''
    : 'printf %s "\$\$" > ${ShellEscaper.escape(pidFile)}; ';

/// Script that reclaims watcher processes whose client is gone.
///
/// The client refreshes [heartbeat] while it is alive. A heartbeat older than
/// [staleAfter] means no one is reading these watchers' output any more — the
/// state that produced 19 orphans, because a watcher blocked in `select()`
/// never writes and so never learns its reader has gone (0025 A).
///
/// Every pid is re-verified against `/proc/<pid>/comm` before being signalled.
/// That check is not ceremony: 0025 records a `ps` selector bug that put the
/// wrong processes in a kill set, caught only because the set was printed
/// before it was used.
String watcherSweepScript(
  List<String> pidFiles, {
  required String heartbeat,
  required Duration staleAfter,
}) {
  final hb = ShellEscaper.escape(heartbeat);
  final files = pidFiles.map(ShellEscaper.escape).join(' ');
  return 'now=\$(date +%s); ts=0; '
      '[ -f $hb ] && ts=\$(stat -c %Y $hb 2>/dev/null || echo 0); '
      '[ "\$((now - ts))" -ge ${staleAfter.inSeconds} ] || exit 0; '
      'for f in $files; do '
      '[ -f "\$f" ] || continue; '
      'p=\$(cat "\$f" 2>/dev/null); '
      'case "\$p" in ""|*[!0-9]*) continue ;; esac; '
      'c=\$(cat /proc/"\$p"/comm 2>/dev/null || echo); '
      'case "\$c" in inotifywait|fswatch) '
      'kill -TERM "\$p" 2>/dev/null; rm -f "\$f" ;; esac; '
      'done; true';
}
