import '../utils/git_porcelain_parser.dart';

/// A node in the repository file tree — pure *structure*, no status.
///
/// Immutable and status-free so it can be built off the UI thread (see
/// [buildRepoTree], run via `Isolate.run` for large repos) and, crucially,
/// **reused across status refreshes**: editing a file changes its git status
/// but not the tree's shape, so the structure graph keeps its identity while the
/// UI recolors from a separate [RepoStatusOverlay]. That decoupling is what lets
/// the file-view pane update atomically instead of rebuilding the whole tree on
/// every save. The widget layer keeps expansion state and lazily-loaded children
/// of collapsed ignored directories separately, so the model never mutates.
class RepoNode {
  /// Last path segment (display label).
  final String name;

  /// Repo-relative path, no leading or trailing slash (root is '').
  final String path;
  final bool isDir;

  /// This node is git-ignored.
  final bool ignored;

  /// A wholly-ignored directory collapsed by `git ls-files --directory`; its
  /// children are not loaded until the user expands it.
  final bool lazy;

  final List<RepoNode> children;

  const RepoNode({
    required this.name,
    required this.path,
    required this.isDir,
    this.ignored = false,
    this.lazy = false,
    this.children = const [],
  });
}

/// The change/"dirty" overlay applied to the (status-free) [RepoNode] tree at
/// render time. Built cheaply from [GitStatus] on every refresh — no tree
/// rebuild — so a save only recolors the affected rows. Derived from
/// [repoDirtyIndex]; see [statusFor] for the collapsed-untracked-dir synthesis.
class RepoStatusOverlay {
  /// Directories that recursively contain an uncommitted change or an unadded
  /// (untracked) file. Never includes ignored subtrees.
  final Set<String> dirtyDirs;

  /// Path → status for individually-reported changed files.
  final Map<String, GitFileStatus> changed;

  /// Wholly-untracked directories git collapsed to a single `dir/` entry; files
  /// listed under them are themselves untracked even though status didn't report
  /// them individually.
  final Set<String> untrackedDirs;

  const RepoStatusOverlay({
    required this.dirtyDirs,
    required this.changed,
    required this.untrackedDirs,
  });

  static const RepoStatusOverlay empty = RepoStatusOverlay(
    dirtyDirs: {},
    changed: {},
    untrackedDirs: {},
  );

  factory RepoStatusOverlay.fromStatus(GitStatus status) {
    final idx = repoDirtyIndex(status);
    return RepoStatusOverlay(
      dirtyDirs: idx.dirtyDirs,
      changed: idx.changed,
      untrackedDirs: idx.untrackedDirs,
    );
  }

  /// Whether [dirPath] should render as "dirty" (green folder).
  bool isDirtyDir(String dirPath) => dirtyDirs.contains(dirPath);

  /// Status for a file leaf, synthesizing `?` for files under a collapsed
  /// untracked directory so they color and open like any other new file. Null
  /// for clean files.
  GitFileStatus? statusFor(String path) {
    final reported = changed[path];
    if (reported != null) return reported;
    if (untrackedDirs.isEmpty) return null;
    var i = path.lastIndexOf('/');
    while (i > 0) {
      final dir = path.substring(0, i);
      if (untrackedDirs.contains(dir)) {
        return GitFileStatus(path: path, statusX: '?', statusY: '?');
      }
      i = dir.lastIndexOf('/');
    }
    return null;
  }
}

/// Derived from [GitStatus] to build a [RepoStatusOverlay]:
///  * [dirtyDirs] — directories containing a change/untracked descendant.
///  * [changed] — path→status for individually-reported changed files.
///  * [untrackedDirs] — wholly-untracked directories that git collapsed to a
///    single `dir/` entry; files listed under them are themselves untracked
///    even though status didn't report them individually.
({
  Set<String> dirtyDirs,
  Map<String, GitFileStatus> changed,
  Set<String> untrackedDirs,
})
repoDirtyIndex(GitStatus status) {
  final dirtyDirs = <String>{};
  final changed = <String, GitFileStatus>{};
  final untrackedDirs = <String>{};

  // Mark every ancestor directory of [path] dirty. Walks upward and stops early
  // once an ancestor is already marked (its own ancestors were marked with it).
  void markAncestors(String path) {
    var idx = path.lastIndexOf('/');
    while (idx > 0) {
      final dir = path.substring(0, idx);
      if (!dirtyDirs.add(dir)) break;
      idx = dir.lastIndexOf('/');
    }
  }

  for (final f in [
    ...status.staged,
    ...status.unstaged,
    ...status.conflicted,
    ...status.untracked,
  ]) {
    final entry = f.path;
    // A wholly-untracked directory arrives collapsed as `dir/`.
    final isDir = entry.endsWith('/');
    final p = isDir ? entry.substring(0, entry.length - 1) : entry;
    if (p.isEmpty) continue;
    if (isDir) {
      dirtyDirs.add(p);
      if (f.isUntracked) untrackedDirs.add(p);
    } else {
      changed[entry] = f;
    }
    markAncestors(p);
  }
  return (dirtyDirs: dirtyDirs, changed: changed, untrackedDirs: untrackedDirs);
}

/// An order-independent hash of the paths whose presence/absence changes the
/// tree's *shape* — untracked entries plus added/deleted/renamed/copied tracked
/// files. A pure content edit shows only as `M`/`T`, leaving this unchanged, so
/// the structure provider can serve its cached tree (no `ls-files`, no rebuild)
/// while a genuine add/delete/rename bumps the hash and triggers one refetch.
///
/// Untracked files are always reported individually (status runs `-uall`
/// precisely so per-file affordances — and this signature — see real paths),
/// so a brand-new file inside an otherwise-untracked directory moves the hash
/// like any other add. The `dir/` handling in [repoDirtyIndex] is kept as a
/// defensive path only.
int structureSignature(GitStatus status) {
  var acc = 0;
  var count = 0;
  void mix(String key) {
    var h = key.hashCode;
    h ^= h >> 16;
    acc ^= h; // XOR ⇒ order-independent
    count++;
  }

  bool affectsShape(GitFileStatus f) =>
      f.statusX == 'A' ||
      f.statusY == 'A' ||
      f.statusX == 'D' ||
      f.statusY == 'D' ||
      f.isRename ||
      f.isCopy;

  for (final f in status.untracked) {
    mix('?${f.path}');
  }
  // `staged` and `unstaged` can both contain the *same* file — a
  // partially-staged entry (e.g. `XY="AM"`: added to the index, then edited
  // again in the worktree before committing, an entirely ordinary workflow)
  // is a single GitFileStatus that satisfies both `isStaged` and `isUnstaged`,
  // so it appears in both lists. Without deduping, its key gets mixed in
  // twice — which cancels to a no-op under XOR — while `count` still
  // double-increments, letting two genuinely different tree shapes collide on
  // the same signature and silently skip a needed rebuild.
  final seen = <String>{};
  for (final f in [
    ...status.staged,
    ...status.unstaged,
    ...status.conflicted,
  ]) {
    if (!affectsShape(f) || !seen.add(f.path)) continue;
    mix('${f.statusX}${f.statusY}:${f.path}');
    final old = f.oldPath;
    if (old != null) mix('~$old'); // rename/copy source path
  }
  return acc ^ (count * 0x27d4eb2f);
}

// Mutable scaffold used only while assembling the tree, then frozen to
// [RepoNode]. Kept private to this library.
class _Mut {
  _Mut(this.name, this.path, {required this.isDir});
  final String name;
  final String path;
  bool isDir;
  bool ignored = false;
  bool lazy = false;
  final Map<String, _Mut> children = {};
}

/// Builds the repository file *structure* from flat path lists.
///
/// [files] are non-ignored paths (tracked + untracked-non-ignored). [ignored]
/// are entries from `git ls-files --ignored --directory`: individual ignored
/// files, or wholly-ignored directories collapsed to a trailing-slash path
/// (rendered as lazy nodes). Change/dirty coloring is applied separately at
/// render time via [RepoStatusOverlay], not baked in here. Children are sorted
/// directories-first, then case-insensitively by name.
RepoNode buildRepoTree({
  required List<String> files,
  required List<String> ignored,
}) {
  final root = _Mut('', '', isDir: true);

  _Mut descend(List<String> segs, {required bool leafIsDir}) {
    var node = root;
    var acc = '';
    for (var i = 0; i < segs.length; i++) {
      final seg = segs[i];
      acc = acc.isEmpty ? seg : '$acc/$seg';
      final isLast = i == segs.length - 1;
      node = node.children.putIfAbsent(
        seg,
        () => _Mut(seg, acc, isDir: !isLast || leafIsDir),
      );
    }
    return node;
  }

  for (final f in files) {
    if (f.isEmpty) continue;
    descend(f.split('/'), leafIsDir: false);
  }

  for (final raw in ignored) {
    if (raw.isEmpty) continue;
    final isDir = raw.endsWith('/');
    final p = isDir ? raw.substring(0, raw.length - 1) : raw;
    if (p.isEmpty) continue;
    final node = descend(p.split('/'), leafIsDir: isDir);
    node.ignored = true;
    if (isDir) {
      node.isDir = true;
      node.lazy = true; // collapsed ignored dir — children fetched on demand
    }
  }

  RepoNode freeze(_Mut m) {
    final kids = m.children.values.map(freeze).toList()
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return RepoNode(
      name: m.name,
      path: m.path,
      isDir: m.isDir,
      ignored: m.ignored,
      lazy: m.lazy,
      children: kids,
    );
  }

  return freeze(root);
}
