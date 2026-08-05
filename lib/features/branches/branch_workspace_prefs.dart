import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/storage/repository_ui_identity.dart';

/// Versioned Branches workspace organization prefs (pins, collapse, mode, …).
///
/// Durable only for [RepositoryUiIdentity.durable] identities. Ad-hoc identities
/// use an in-memory map keyed by [RepositoryUiIdentity.memoryKey].
class BranchWorkspacePrefs {
  static const int currentVersion = 1;

  final int version;
  final List<String> pinnedBranchNames;
  final List<String> hiddenBranchNames;
  final bool grouped;
  final Set<String> collapsedSections;
  final Set<String> collapsedFolderPrefixes;
  final String lastMode; // 'browse' | 'review'
  final String browseSort;
  final String reviewSort;
  final String? selectedBaseRefName;
  final bool showHidden;

  const BranchWorkspacePrefs({
    this.version = currentVersion,
    this.pinnedBranchNames = const [],
    this.hiddenBranchNames = const [],
    this.grouped = false,
    this.collapsedSections = const {},
    this.collapsedFolderPrefixes = const {},
    this.lastMode = 'browse',
    this.browseSort = 'default',
    this.reviewSort = 'smart',
    this.selectedBaseRefName,
    this.showHidden = false,
  });

  BranchWorkspacePrefs copyWith({
    int? version,
    List<String>? pinnedBranchNames,
    List<String>? hiddenBranchNames,
    bool? grouped,
    Set<String>? collapsedSections,
    Set<String>? collapsedFolderPrefixes,
    String? lastMode,
    String? browseSort,
    String? reviewSort,
    String? selectedBaseRefName,
    bool clearSelectedBaseRefName = false,
    bool? showHidden,
  }) {
    return BranchWorkspacePrefs(
      version: version ?? this.version,
      pinnedBranchNames: pinnedBranchNames ?? this.pinnedBranchNames,
      hiddenBranchNames: hiddenBranchNames ?? this.hiddenBranchNames,
      grouped: grouped ?? this.grouped,
      collapsedSections: collapsedSections ?? this.collapsedSections,
      collapsedFolderPrefixes:
          collapsedFolderPrefixes ?? this.collapsedFolderPrefixes,
      lastMode: lastMode ?? this.lastMode,
      browseSort: browseSort ?? this.browseSort,
      reviewSort: reviewSort ?? this.reviewSort,
      selectedBaseRefName: clearSelectedBaseRefName
          ? null
          : (selectedBaseRefName ?? this.selectedBaseRefName),
      showHidden: showHidden ?? this.showHidden,
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'pinnedBranchNames': pinnedBranchNames,
    'hiddenBranchNames': hiddenBranchNames,
    'grouped': grouped,
    'collapsedSections': collapsedSections.toList()..sort(),
    'collapsedFolderPrefixes': collapsedFolderPrefixes.toList()..sort(),
    'lastMode': lastMode,
    'browseSort': browseSort,
    'reviewSort': reviewSort,
    'selectedBaseRefName': selectedBaseRefName,
    'showHidden': showHidden,
  };

  factory BranchWorkspacePrefs.fromJson(Map<String, Object?> json) {
    List<String> strings(Object? v) {
      if (v is! List) return const [];
      return [
        for (final e in v)
          if (e is String) e,
      ];
    }

    Set<String> stringSet(Object? v) => strings(v).toSet();

    return BranchWorkspacePrefs(
      version: (json['version'] as int?) ?? currentVersion,
      pinnedBranchNames: strings(json['pinnedBranchNames']),
      hiddenBranchNames: strings(json['hiddenBranchNames']),
      grouped: (json['grouped'] as bool?) ?? false,
      collapsedSections: stringSet(json['collapsedSections']),
      collapsedFolderPrefixes: stringSet(json['collapsedFolderPrefixes']),
      lastMode: (json['lastMode'] as String?) ?? 'browse',
      browseSort: (json['browseSort'] as String?) ?? 'default',
      reviewSort: (json['reviewSort'] as String?) ?? 'smart',
      selectedBaseRefName: json['selectedBaseRefName'] as String?,
      showHidden: (json['showHidden'] as bool?) ?? false,
    );
  }

  String encode() => jsonEncode(toJson());

  static BranchWorkspacePrefs decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const BranchWorkspacePrefs();
    }
    return BranchWorkspacePrefs.fromJson(Map<String, Object?>.from(decoded));
  }

  /// Preference storage key for a durable identity.
  static String storageKeyFor(RepositoryUiIdentity identity) =>
      'branchWorkspacePrefs_v1_${identity.preferenceKey}';

  /// Migrate legacy path-keyed pins + global branch collapse bits.
  ///
  /// Does not delete legacy keys. [legacyPins] comes from
  /// `pinnedBranches_<repoPath>`. [globalCollapsed] is the global
  /// `collapsedSections` set; only `branches.*` keys are imported.
  static BranchWorkspacePrefs migrateFromLegacy({
    required Set<String> legacyPins,
    required Set<String> globalCollapsed,
  }) {
    final branchCollapse = {
      for (final k in globalCollapsed)
        if (k.startsWith('branches.')) k,
    };
    return BranchWorkspacePrefs(
      pinnedBranchNames: legacyPins.toList()..sort(),
      collapsedSections: branchCollapse,
    );
  }
}

/// In-memory store for ad-hoc (non-durable) workspace prefs.
final Map<String, BranchWorkspacePrefs> _sessionWorkspacePrefs = {};

/// Clears ad-hoc prefs (call from connection invalidate / disconnect).
void clearSessionBranchWorkspacePrefs() {
  _sessionWorkspacePrefs.clear();
}

/// Reads the legacy global collapse store for one-time workspace migration.
Future<Set<String>> loadLegacyBranchCollapsedSections() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('collapsedSections') ?? const <String>[])
        .where((key) => key.startsWith('branches.'))
        .toSet();
  } catch (_) {
    return const {};
  }
}

/// Load prefs for [identity], migrating legacy pins/collapse when durable and
/// no new record exists yet.
Future<BranchWorkspacePrefs> loadBranchWorkspacePrefs({
  required RepositoryUiIdentity identity,
  required String? legacyRepoPath,
  Set<String> globalCollapsed = const {},
}) async {
  if (!identity.durable) {
    return _sessionWorkspacePrefs[identity.memoryKey] ??
        const BranchWorkspacePrefs();
  }

  final prefs = await SharedPreferences.getInstance();
  final key = BranchWorkspacePrefs.storageKeyFor(identity);
  final raw = prefs.getString(key);
  if (raw != null && raw.isNotEmpty) {
    return BranchWorkspacePrefs.decode(raw);
  }

  Set<String> legacyPins = const {};
  if (legacyRepoPath != null) {
    final list = prefs.getStringList('pinnedBranches_$legacyRepoPath');
    if (list != null) legacyPins = list.toSet();
  }

  final migrated = BranchWorkspacePrefs.migrateFromLegacy(
    legacyPins: legacyPins,
    globalCollapsed: globalCollapsed,
  );
  // Write once so subsequent loads skip migration.
  await prefs.setString(key, migrated.encode());
  return migrated;
}

/// Persist [next] for a durable identity, or store in-memory for ad-hoc.
Future<void> saveBranchWorkspacePrefs({
  required RepositoryUiIdentity identity,
  required BranchWorkspacePrefs next,
}) async {
  if (!identity.durable) {
    _sessionWorkspacePrefs[identity.memoryKey] = next;
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    BranchWorkspacePrefs.storageKeyFor(identity),
    next.encode(),
  );
}

/// Per-identity write chain so concurrent pin / mode / base / collapse updates
/// cannot last-write-wins clobber each other (Phase 0 single-writer rule).
final Map<String, Future<void>> _prefsWriteChains = {};

Future<T> _serializedPrefsWrite<T>(
  String lockKey,
  Future<T> Function() body,
) async {
  final previous = _prefsWriteChains[lockKey] ?? Future<void>.value();
  final gate = Completer<void>();
  _prefsWriteChains[lockKey] = gate.future;
  try {
    await previous;
    return await body();
  } finally {
    gate.complete();
    if (identical(_prefsWriteChains[lockKey], gate.future)) {
      // remove() returns the prior Future; do not await it (already finished).
      unawaited(_prefsWriteChains.remove(lockKey) ?? Future<void>.value());
    }
  }
}

String _prefsLockKey(RepositoryUiIdentity identity) =>
    identity.durable ? identity.preferenceKey : identity.memoryKey;

/// Load → [update] → save under a per-identity mutex. Call sites that mutate
/// workspace prefs (pins, mode, base, collapse, grouping) must use this so
/// concurrent UI actions cannot drop each other's fields.
Future<BranchWorkspacePrefs> updateBranchWorkspacePrefs({
  required RepositoryUiIdentity identity,
  required BranchWorkspacePrefs Function(BranchWorkspacePrefs) update,
  String? legacyRepoPath,
  Set<String> globalCollapsed = const {},
}) {
  return _serializedPrefsWrite(_prefsLockKey(identity), () async {
    final current = await loadBranchWorkspacePrefs(
      identity: identity,
      legacyRepoPath: legacyRepoPath,
      globalCollapsed: globalCollapsed,
    );
    final next = update(current);
    await saveBranchWorkspacePrefs(identity: identity, next: next);
    return next;
  });
}

/// Merge [incoming] into [current], preserving fields the user has already
/// touched this session (mode, base, pins when [touched] is set).
///
/// [touchedMode], [touchedBase], [touchedPins] mark fields that must not be
/// clobbered by a late prefs load.
BranchWorkspacePrefs mergeLateLoadedPrefs({
  required BranchWorkspacePrefs current,
  required BranchWorkspacePrefs incoming,
  bool touchedMode = false,
  bool touchedBase = false,
  bool touchedPins = false,
}) {
  return BranchWorkspacePrefs(
    version: incoming.version,
    pinnedBranchNames: touchedPins
        ? current.pinnedBranchNames
        : incoming.pinnedBranchNames,
    hiddenBranchNames: incoming.hiddenBranchNames,
    grouped: incoming.grouped,
    collapsedSections: incoming.collapsedSections,
    collapsedFolderPrefixes: incoming.collapsedFolderPrefixes,
    lastMode: touchedMode ? current.lastMode : incoming.lastMode,
    browseSort: incoming.browseSort,
    reviewSort: incoming.reviewSort,
    selectedBaseRefName: touchedBase
        ? current.selectedBaseRefName
        : incoming.selectedBaseRefName,
    showHidden: incoming.showHidden,
  );
}
