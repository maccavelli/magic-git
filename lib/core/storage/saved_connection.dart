import '../utils/posix_path.dart';

/// Non-secret connection profile metadata, persisted in shared_preferences.
/// The secret (SSH password/passphrase) is stored separately in the Keychain,
/// referenced by [id].

class SavedConnection {
  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final String repoPath; // Default/last-used repo
  final List<String> repoPaths; // All known repos on this host, for switching
  /// Repo paths (a subset of [allRepoPaths]) with git fsmonitor enabled on the
  /// remote. Per-repo and opt-in: empty means off for every repo. Toggled from
  /// the connections management panel.
  final List<String> fsmonitorPaths;

  /// Friendly display names for individual repos, keyed by repo path. Per-repo
  /// and optional (the parallel-map analogue of [fsmonitorPaths]): a path
  /// absent here — or mapped to an empty string — falls back to its directory
  /// basename, so existing profiles round-trip with no migration. Set from the
  /// Add/Edit repository cards, mirroring [SavedLocalRepo.label].
  final Map<String, String> repoLabels;

  /// Scoped work-tree (dotfiles) repos: repo path → the external git-dir for it
  /// (e.g. `/home/u` → `/home/u/.home.git`). Per-repo and optional, the
  /// parallel-map analogue of [repoLabels]/[fsmonitorPaths]: a path absent here
  /// is an ordinary repo whose `.git` is inside it, so existing profiles
  /// round-trip with no migration. When present, connect registers
  /// `GIT_DIR`/`GIT_WORK_TREE` for that repo and the watcher runs bounded — see
  /// `bounded_watch.dart` / `GitService.registerRepoScope`.
  final Map<String, String> scopedGitDirs;

  /// Forge namespaces recently created into on this connection, keyed by
  /// `<forge>@<host>` and most-recent-first. The parallel-map analogue of
  /// [repoLabels]/[scopedGitDirs]: a key absent here simply has no history, so
  /// existing profiles round-trip with no migration (MADR 0032 Phase 3b).
  ///
  /// Keyed by forge **and** host because a namespace is meaningless across
  /// them — a GitLab group is not a GitHub org, and two GitLab instances are
  /// different accounts.
  ///
  /// **This is only half the story.** A This-Mac create has no connection to
  /// hang history on, and its forge account is the Mac's own `gh`/`glab`
  /// login — see `core/forge/namespace_history.dart`, which owns that case.
  /// Read and write both through `NamespaceHistory`, never directly.
  final Map<String, List<String>> namespaceHistory;

  /// When each remembered namespace was last used — `<forge>@<host>` →
  /// namespace → ISO-8601 instant (MADR 0032 Phase 8).
  ///
  /// **A parallel map, deliberately, so [namespaceHistory] keeps its shape.**
  /// Folding the time into the list would change a stored format that Phase 3b
  /// designed to need no migration, and there is a test asserting a profile
  /// with history round-trips unchanged. Absent means "recorded before times
  /// were kept" — the row simply shows no time, and gains one on next use.
  /// Same idiom as `repoLabels`/`scopedGitDirs`.
  final Map<String, Map<String, String>> namespaceHistoryTimes;

  /// When this profile was last successfully connected — drives the landing
  /// page's "Recent Connections" ordering. Null for never-connected profiles.
  final DateTime? lastConnectedAt;

  const SavedConnection({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.repoPath,
    this.repoPaths = const [],
    this.fsmonitorPaths = const [],
    this.repoLabels = const {},
    this.scopedGitDirs = const {},
    this.namespaceHistory = const {},
    this.namespaceHistoryTimes = const {},
    this.lastConnectedAt,
  });

  /// Order-preserving de-duplication of repo paths, dropping null/empty. The one
  /// place this collapse is implemented, reused by [allRepoPaths] and by the
  /// connect/save flows.
  static List<String> dedupePaths(Iterable<String?> paths) => <String>{
    for (final p in paths)
      if (p != null && p.isNotEmpty) p,
  }.toList();

  /// The known repos, guaranteeing [repoPath] is included and first.
  List<String> get allRepoPaths => dedupePaths([repoPath, ...repoPaths]);

  /// Whether git fsmonitor is enabled for [path] on this connection.
  bool fsmonitorEnabledFor(String path) => fsmonitorPaths.contains(path);

  /// A copy with fsmonitor turned on/off for [path] (order-preserving, deduped).
  SavedConnection withFsmonitor(String path, bool enabled) => copyWith(
    fsmonitorPaths: enabled
        ? dedupePaths([...fsmonitorPaths, path])
        : fsmonitorPaths.where((p) => p != path).toList(),
  );

  /// The stored friendly label for [path], or an empty string if none — the
  /// per-repo analogue of the profile's own [label].
  String repoLabelFor(String path) => repoLabels[path] ?? '';

  /// A copy with [path]'s friendly label set (or cleared, when [label] is
  /// empty — an absent key means "fall back to the basename", so an empty
  /// label is never persisted). Mirrors [withFsmonitor].
  SavedConnection withRepoLabel(String path, String label) {
    final next = Map<String, String>.from(repoLabels);
    if (label.isEmpty) {
      next.remove(path);
    } else {
      next[path] = label;
    }
    return copyWith(repoLabels: next);
  }

  /// The external git-dir for [path] if it's a scoped work-tree (dotfiles)
  /// repo, else an empty string (an ordinary repo).
  String scopedGitDirFor(String path) => scopedGitDirs[path] ?? '';

  /// A copy with [path] marked scoped to [gitDir] (or unmarked, when [gitDir]
  /// is empty — an absent key means "ordinary repo"). Mirrors [withRepoLabel].
  SavedConnection withScopedGitDir(String path, String gitDir) {
    final next = Map<String, String>.from(scopedGitDirs);
    if (gitDir.isEmpty) {
      next.remove(path);
    } else {
      next[path] = gitDir;
    }
    return copyWith(scopedGitDirs: next);
  }

  /// How [path] should appear in the UI: its friendly label when set, else the
  /// directory basename. The remote analogue of [SavedLocalRepo.displayName].
  String repoDisplayName(String path) {
    final label = repoLabels[path];
    return (label != null && label.isNotEmpty) ? label : basename(path);
  }

  SavedConnection copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    String? repoPath,
    List<String>? repoPaths,
    List<String>? fsmonitorPaths,
    Map<String, String>? repoLabels,
    Map<String, String>? scopedGitDirs,
    Map<String, List<String>>? namespaceHistory,
    Map<String, Map<String, String>>? namespaceHistoryTimes,
    DateTime? lastConnectedAt,
  }) => SavedConnection(
    id: id,
    label: label ?? this.label,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    repoPath: repoPath ?? this.repoPath,
    repoPaths: repoPaths ?? this.repoPaths,
    fsmonitorPaths: fsmonitorPaths ?? this.fsmonitorPaths,
    repoLabels: repoLabels ?? this.repoLabels,
    scopedGitDirs: scopedGitDirs ?? this.scopedGitDirs,
    namespaceHistory: namespaceHistory ?? this.namespaceHistory,
    namespaceHistoryTimes: namespaceHistoryTimes ?? this.namespaceHistoryTimes,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );

  /// Namespaces recently created into for [forgeHostKey], most recent first.
  List<String> namespacesFor(String forgeHostKey) =>
      namespaceHistory[forgeHostKey] ?? const [];

  /// Records [namespace] as the most recent use for [forgeHostKey], keeping at
  /// most [maxNamespaceHistory] entries. Mirrors [withRepoLabel]/[withFsmonitor].
  SavedConnection withNamespaceUse(
    String forgeHostKey,
    String namespace, {
    DateTime? at,
  }) {
    if (namespace.isEmpty) return this;
    final next = <String>[
      namespace,
      ...namespacesFor(forgeHostKey).where((n) => n != namespace),
    ].take(maxNamespaceHistory).toList();
    // Times are pruned alongside the list they annotate, or the map grows
    // without bound behind a list that does not.
    final times = {
      ...?namespaceHistoryTimes[forgeHostKey],
      namespace: (at ?? DateTime.now()).toUtc().toIso8601String(),
    }..removeWhere((ns, _) => !next.contains(ns));
    return copyWith(
      namespaceHistory: {...namespaceHistory, forgeHostKey: next},
      namespaceHistoryTimes: {...namespaceHistoryTimes, forgeHostKey: times},
    );
  }

  /// When each remembered namespace under [forgeHostKey] was last used.
  /// Entries missing from this map were recorded before times were kept.
  Map<String, DateTime> namespaceTimesFor(String forgeHostKey) {
    final raw = namespaceHistoryTimes[forgeHostKey];
    if (raw == null) return const {};
    final out = <String, DateTime>{};
    for (final entry in raw.entries) {
      final at = DateTime.tryParse(entry.value);
      if (at != null) out[entry.key] = at;
    }
    return out;
  }

  /// Bound on per-key history. A create wizard offers a short list; keeping
  /// more would persist noise nobody reads.
  static const int maxNamespaceHistory = 10;

  static Map<String, List<String>> _readNamespaceHistory(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! List) continue;
      final items = value.whereType<String>().where((s) => s.isNotEmpty);
      if (items.isEmpty) continue;
      out[key] = items.toList();
    }
    return out;
  }

  static Map<String, Map<String, String>> _readNamespaceTimes(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Map<String, String>>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) continue;
      final inner = <String, String>{};
      for (final e in value.entries) {
        if (e.key is String && e.value is String) {
          inner[e.key as String] = e.value as String;
        }
      }
      if (inner.isNotEmpty) out[key] = inner;
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'host': host,
    'port': port,
    'username': username,
    'repoPath': repoPath,
    'repoPaths': repoPaths,
    'fsmonitorPaths': fsmonitorPaths,
    if (repoLabels.isNotEmpty) 'repoLabels': repoLabels,
    if (scopedGitDirs.isNotEmpty) 'scopedGitDirs': scopedGitDirs,
    if (namespaceHistory.isNotEmpty) 'namespaceHistory': namespaceHistory,
    if (namespaceHistoryTimes.isNotEmpty)
      'namespaceHistoryTimes': namespaceHistoryTimes,
    if (lastConnectedAt != null)
      'lastConnectedAt': lastConnectedAt!.toIso8601String(),
  };

  factory SavedConnection.fromJson(
    Map<String, dynamic> json,
  ) => SavedConnection(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    host: json['host'] as String? ?? '',
    port: (json['port'] as num?)?.toInt() ?? 22,
    username: json['username'] as String? ?? '',
    repoPath: json['repoPath'] as String? ?? '',
    repoPaths:
        (json['repoPaths'] as List?)?.whereType<String>().toList() ?? const [],
    fsmonitorPaths: _readFsmonitorPaths(json),
    repoLabels: _readRepoLabels(json),
    scopedGitDirs: _readStringMap(json['scopedGitDirs']),
    namespaceHistory: _readNamespaceHistory(json['namespaceHistory']),
    namespaceHistoryTimes: _readNamespaceTimes(json['namespaceHistoryTimes']),
    lastConnectedAt: DateTime.tryParse(
      json['lastConnectedAt'] as String? ?? '',
    ),
  );

  // Reads the per-repo fsmonitor set, migrating the legacy connection-level
  // `enableFsmonitor: true` flag to enabling fsmonitor for the default repo.
  static List<String> _readFsmonitorPaths(Map<String, dynamic> json) {
    final list = (json['fsmonitorPaths'] as List?)
        ?.whereType<String>()
        .toList();
    if (list != null) return list;
    if ((json['enableFsmonitor'] as bool?) ?? false) {
      final repo = json['repoPath'] as String? ?? '';
      return repo.isEmpty ? const [] : [repo];
    }
    return const [];
  }

  // Reads the per-repo label map, coercing keys/values to String and dropping
  // empty labels (an absent key already means "use the basename"). Absent on
  // older profiles → an empty map, so nothing needs migrating.
  static Map<String, String> _readRepoLabels(Map<String, dynamic> json) =>
      _readStringMap(json['repoLabels']);

  // Shared String→String map reader (used by repoLabels and scopedGitDirs):
  // coerces keys/values to String, drops empty entries, and returns a const
  // empty map for anything that isn't a JSON object — so an absent or malformed
  // key needs no migration.
  static Map<String, String> _readStringMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((k, v) {
      final key = k.toString();
      final value = v?.toString() ?? '';
      if (key.isNotEmpty && value.isNotEmpty) out[key] = value;
    });
    return out;
  }

  /// A human label falling back to `user@host` when none was given.
  String get displayName => label.isNotEmpty ? label : '$username@$host';
}
