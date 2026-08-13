import 'package:flutter/foundation.dart';

/// The persisted backend discriminator for a saved repository reference.
enum SavedRepositoryKind { ssh, local }

/// Stable, non-secret repository identity used by workspace sets and aliases.
///
/// This deliberately uses the saved connection/local-repository id plus the
/// repository path. Runtime tab ids, credentials, and bookmark bytes never
/// participate in the identity or its serialized form.
class SavedRepositoryIdentity {
  final SavedRepositoryKind kind;
  final String savedId;
  final String repoPath;

  const SavedRepositoryIdentity({
    required this.kind,
    required this.savedId,
    required this.repoPath,
  });

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'savedId': savedId,
    'repoPath': repoPath,
  };

  factory SavedRepositoryIdentity.fromJson(Map<String, dynamic> json) {
    final kind = SavedRepositoryKind.values
        .where((value) => value.name == json['kind'])
        .firstOrNull;
    final savedId = (json['savedId'] as String? ?? '').trim();
    final repoPath = (json['repoPath'] as String? ?? '').trim();
    if (kind == null || savedId.isEmpty || repoPath.isEmpty) {
      throw const FormatException('Invalid saved repository identity');
    }
    return SavedRepositoryIdentity(
      kind: kind,
      savedId: savedId,
      repoPath: repoPath,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedRepositoryIdentity &&
      other.kind == kind &&
      other.savedId == savedId &&
      other.repoPath == repoPath;

  @override
  int get hashCode => Object.hash(kind, savedId, repoPath);
}

/// One ordered member of a [SavedWorkspaceSet].
class SavedWorkspaceRepositoryRef {
  static const _knownPresetNames = {
    'review',
    'commit',
    'investigate',
    'minimal',
  };

  final SavedRepositoryKind kind;
  final String savedId;
  final String repoPath;
  final String? tabAlias;
  final String? layoutPresetName;

  const SavedWorkspaceRepositoryRef({
    required this.kind,
    required this.savedId,
    required this.repoPath,
    this.tabAlias,
    this.layoutPresetName,
  });

  SavedRepositoryIdentity get identity =>
      SavedRepositoryIdentity(kind: kind, savedId: savedId, repoPath: repoPath);

  SavedWorkspaceRepositoryRef get normalized {
    final normalizedId = savedId.trim();
    final normalizedPath = repoPath.trim();
    if (normalizedId.isEmpty || normalizedPath.isEmpty) {
      throw const FormatException('Invalid saved workspace repository');
    }
    final alias = tabAlias?.trim();
    final preset = layoutPresetName?.trim().toLowerCase();
    return SavedWorkspaceRepositoryRef(
      kind: kind,
      savedId: normalizedId,
      repoPath: normalizedPath,
      tabAlias: alias == null || alias.isEmpty ? null : alias,
      layoutPresetName: preset != null && _knownPresetNames.contains(preset)
          ? preset
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    final value = normalized;
    return {
      ...value.identity.toJson(),
      if (value.tabAlias != null) 'tabAlias': value.tabAlias,
      if (value.layoutPresetName != null)
        'layoutPresetName': value.layoutPresetName,
    };
  }

  factory SavedWorkspaceRepositoryRef.fromJson(Map<String, dynamic> json) {
    final identity = SavedRepositoryIdentity.fromJson(json);
    return SavedWorkspaceRepositoryRef(
      kind: identity.kind,
      savedId: identity.savedId,
      repoPath: identity.repoPath,
      tabAlias: json['tabAlias'] as String?,
      layoutPresetName: json['layoutPresetName'] as String?,
    ).normalized;
  }

  @override
  bool operator ==(Object other) =>
      other is SavedWorkspaceRepositoryRef &&
      other.kind == kind &&
      other.savedId == savedId &&
      other.repoPath == repoPath &&
      other.tabAlias == tabAlias &&
      other.layoutPresetName == layoutPresetName;

  @override
  int get hashCode =>
      Object.hash(kind, savedId, repoPath, tabAlias, layoutPresetName);
}

/// A named, ordered multi-repository workspace.
///
/// Version 1 stores reference-only metadata. In particular, local repository
/// bookmark bytes remain solely in [SavedLocalRepo], and SSH secrets remain in
/// [ConnectionStore].
class SavedWorkspaceSet {
  static const int currentVersion = 1;

  final int version;
  final String id;
  final String displayName;
  final List<SavedWorkspaceRepositoryRef> repositories;
  final int activeIndex;

  const SavedWorkspaceSet({
    this.version = currentVersion,
    required this.id,
    required this.displayName,
    required this.repositories,
    required this.activeIndex,
  });

  SavedWorkspaceSet get normalized {
    if (version != currentVersion) {
      throw FormatException('Unsupported saved workspace version: $version');
    }
    final normalizedId = id.trim();
    final normalizedName = displayName.trim();
    if (normalizedId.isEmpty || normalizedName.isEmpty) {
      throw const FormatException('Invalid saved workspace set');
    }
    final members = [for (final member in repositories) member.normalized];
    final normalizedActive = members.isEmpty
        ? 0
        : activeIndex.clamp(0, members.length - 1);
    return SavedWorkspaceSet(
      id: normalizedId,
      displayName: normalizedName,
      repositories: members,
      activeIndex: normalizedActive,
    );
  }

  Map<String, dynamic> toJson() {
    final value = normalized;
    return {
      'version': value.version,
      'id': value.id,
      'displayName': value.displayName,
      'repositories': [
        for (final repository in value.repositories) repository.toJson(),
      ],
      'activeIndex': value.activeIndex,
    };
  }

  factory SavedWorkspaceSet.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version != currentVersion) {
      throw FormatException('Unsupported saved workspace version: $version');
    }
    final rawRepositories = json['repositories'];
    if (rawRepositories is! List) {
      throw const FormatException('Invalid saved workspace repositories');
    }
    final repositories = <SavedWorkspaceRepositoryRef>[];
    for (final raw in rawRepositories) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid saved workspace member');
      }
      repositories.add(SavedWorkspaceRepositoryRef.fromJson(raw));
    }
    return SavedWorkspaceSet(
      version: version,
      id: json['id'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      repositories: repositories,
      activeIndex: (json['activeIndex'] as num?)?.toInt() ?? 0,
    ).normalized;
  }

  @override
  bool operator ==(Object other) =>
      other is SavedWorkspaceSet &&
      other.version == version &&
      other.id == id &&
      other.displayName == displayName &&
      listEquals(other.repositories, repositories) &&
      other.activeIndex == activeIndex;

  @override
  int get hashCode => Object.hash(
    version,
    id,
    displayName,
    Object.hashAll(repositories),
    activeIndex,
  );
}
