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

  SavedConnection copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    String? repoPath,
    List<String>? repoPaths,
    List<String>? fsmonitorPaths,
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
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'host': host,
    'port': port,
    'username': username,
    'repoPath': repoPath,
    'repoPaths': repoPaths,
    'fsmonitorPaths': fsmonitorPaths,
    if (lastConnectedAt != null)
      'lastConnectedAt': lastConnectedAt!.toIso8601String(),
  };

  factory SavedConnection.fromJson(Map<String, dynamic> json) =>
      SavedConnection(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String? ?? '',
        repoPath: json['repoPath'] as String? ?? '',
        repoPaths:
            (json['repoPaths'] as List?)?.whereType<String>().toList() ??
            const [],
        fsmonitorPaths: _readFsmonitorPaths(json),
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

  /// A human label falling back to `user@host` when none was given.
  String get displayName => label.isNotEmpty ? label : '$username@$host';
}
