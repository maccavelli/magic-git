/// A bookmarked local-filesystem repo, persisted in shared_preferences.
/// Unlike [SavedConnection], there is no secret at all — no password, key, or
/// token — only a picked folder path, a macOS security-scoped bookmark (so it
/// can be reopened without re-prompting the Finder panel; see
/// `SecurityScopedBookmark`), and display/fsmonitor metadata. Kept as a
/// sibling type to `SavedConnection` rather than retrofitted into it, since
/// `SavedConnection`'s `host`/`port`/`username` are required fields with no
/// "this has no host" discriminator — this avoids any risk to the existing,
/// well-tested SSH connection storage.
class SavedLocalRepo {
  final String id;
  final String label;
  final String repoPath;

  /// Base64-encoded macOS security-scoped bookmark data for [repoPath].
  /// Empty if a bookmark couldn't be created (e.g. sandboxing disabled, or
  /// bookmark creation failed) — reopening then falls back to re-picking the
  /// folder via the Finder panel instead of resolving silently.
  final String bookmarkData;

  /// For a **linked worktree**: the main repository's working-tree root, whose
  /// `.git` holds this worktree's HEAD/index and all the shared objects and
  /// refs. Empty for an ordinary repo.
  ///
  /// A linked worktree needs TWO security-scoped grants to be usable under the
  /// sandbox — its own folder and the main repo's — because a bare `git status`
  /// in it reads both. [mainRepoBookmarkData] is the second grant;
  /// `ConnectionController` acquires both through `ScopedAccess`, which
  /// refcounts them so two tabs on the same main repo can't revoke each other's.
  final String mainRepoPath;

  /// Base64 security-scoped bookmark for [mainRepoPath]. Empty when this isn't
  /// a linked worktree, or when the grant couldn't be persisted — in which case
  /// reopening re-prompts for the main repo folder rather than failing with a
  /// raw permission error.
  final String mainRepoBookmarkData;

  /// Whether git fsmonitor is enabled for this repo — a perf feature
  /// independent of transport, so it's just as meaningful for a local repo as
  /// an SSH one.
  final bool fsmonitorEnabled;

  /// For a **scoped work-tree repo** (the dotfiles pattern): the git-dir that
  /// lives OUTSIDE [repoPath], with [repoPath] itself as the work tree (e.g.
  /// `repoPath` = `$HOME`, `gitDir` = `~/.home.git`). Empty for an ordinary
  /// repo whose `.git` is inside [repoPath].
  ///
  /// When set, the connect flow registers `GIT_DIR`/`GIT_WORK_TREE` on the
  /// GitService (so every command targets the external git-dir) and the watcher
  /// switches to the bounded, tracked-files-only surface instead of recursing
  /// the whole work tree. See `bounded_watch.dart` / `GitService.registerRepoScope`.
  final String gitDir;

  /// When this repo was last opened — drives recency ordering, mirroring
  /// [SavedConnection.lastConnectedAt]. Null for never-opened entries.
  final DateTime? lastConnectedAt;

  const SavedLocalRepo({
    required this.id,
    required this.label,
    required this.repoPath,
    this.bookmarkData = '',
    this.mainRepoPath = '',
    this.mainRepoBookmarkData = '',
    this.fsmonitorEnabled = false,
    this.gitDir = '',
    this.lastConnectedAt,
  });

  /// True when this entry is a linked worktree — i.e. it names a main repo that
  /// must be granted alongside it.
  bool get isLinkedWorktree => mainRepoPath.isNotEmpty;

  /// True when this entry is a scoped work-tree (dotfiles) repo — its git-dir
  /// lives outside the work tree.
  bool get isScoped => gitDir.isNotEmpty;

  SavedLocalRepo copyWith({
    String? label,
    String? bookmarkData,
    String? mainRepoPath,
    String? mainRepoBookmarkData,
    bool? fsmonitorEnabled,
    String? gitDir,
    DateTime? lastConnectedAt,
  }) => SavedLocalRepo(
    id: id,
    label: label ?? this.label,
    repoPath: repoPath,
    bookmarkData: bookmarkData ?? this.bookmarkData,
    mainRepoPath: mainRepoPath ?? this.mainRepoPath,
    mainRepoBookmarkData: mainRepoBookmarkData ?? this.mainRepoBookmarkData,
    fsmonitorEnabled: fsmonitorEnabled ?? this.fsmonitorEnabled,
    gitDir: gitDir ?? this.gitDir,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'repoPath': repoPath,
    'bookmarkData': bookmarkData,
    // Omitted entirely for an ordinary repo, so existing entries round-trip
    // byte-identical and nothing else has to know about worktrees.
    if (mainRepoPath.isNotEmpty) 'mainRepoPath': mainRepoPath,
    if (mainRepoBookmarkData.isNotEmpty)
      'mainRepoBookmarkData': mainRepoBookmarkData,
    'fsmonitorEnabled': fsmonitorEnabled,
    // Omitted for an ordinary repo, so existing entries round-trip identically.
    if (gitDir.isNotEmpty) 'gitDir': gitDir,
    if (lastConnectedAt != null)
      'lastConnectedAt': lastConnectedAt!.toIso8601String(),
  };

  factory SavedLocalRepo.fromJson(Map<String, dynamic> json) =>
      SavedLocalRepo(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        repoPath: json['repoPath'] as String? ?? '',
        bookmarkData: json['bookmarkData'] as String? ?? '',
        // Absent in every entry persisted before worktrees existed — defaulting
        // to empty migrates them silently as ordinary repos.
        mainRepoPath: json['mainRepoPath'] as String? ?? '',
        mainRepoBookmarkData: json['mainRepoBookmarkData'] as String? ?? '',
        fsmonitorEnabled: json['fsmonitorEnabled'] as bool? ?? false,
        // Absent on entries persisted before scoped repos existed → empty,
        // migrating them silently as ordinary repos.
        gitDir: json['gitDir'] as String? ?? '',
        lastConnectedAt: DateTime.tryParse(
          json['lastConnectedAt'] as String? ?? '',
        ),
      );

  /// A human label falling back to the folder's basename when none was given
  /// — mirrors [SavedConnection.displayName]'s `user@host` fallback.
  String get displayName => label.isNotEmpty ? label : _basename(repoPath);

  static String _basename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}
