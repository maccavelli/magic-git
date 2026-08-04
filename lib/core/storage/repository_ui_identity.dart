import 'dart:convert';

/// Scope of a repository UI identity for preference and cache keying.
///
/// Durable scopes outlive the process (SharedPreferences). Session scopes are
/// in-memory only for ad-hoc connections (`ConnectionState.connectionId == null`).
enum RepositoryUiIdentityScope {
  /// Saved SSH profile: `ssh:<SavedConnection.id>`.
  ssh,

  /// Saved local bookmark: `local:<SavedLocalRepo.id>`.
  local,

  /// Ad-hoc SSH or local session: never written to disk.
  adhoc,
}

/// Stable key material for Branches (and future) workspace preferences.
///
/// Composite identity is:
/// ```text
/// <scopePrefix> + NUL + <canonical gitCommonDir>
/// ```
/// encoded as UTF-8 base64url (no padding) for SharedPreferences keys.
///
/// Durable only for [RepositoryUiIdentityScope.ssh] / [.local]. Ad-hoc keys
/// include [sessionEpoch] so two sequential sessions on the same path never
/// collide in an in-memory map.
class RepositoryUiIdentity {
  final RepositoryUiIdentityScope scope;

  /// `ssh:<id>`, `local:<id>`, or `adhoc:<backend>:<sessionEpoch>`.
  final String scopeKey;

  /// Canonical absolute common git dir from [RepoLayout.gitCommonDir].
  final String gitCommonDir;

  /// True only for saved SSH/local identities that may write SharedPreferences.
  final bool durable;

  /// Connection attempt generation for ad-hoc scopes; null for durable scopes.
  final int? sessionEpoch;

  const RepositoryUiIdentity._({
    required this.scope,
    required this.scopeKey,
    required this.gitCommonDir,
    required this.durable,
    this.sessionEpoch,
  });

  /// Saved SSH connection identity.
  factory RepositoryUiIdentity.ssh({
    required String connectionId,
    required String gitCommonDir,
  }) {
    assert(connectionId.isNotEmpty);
    return RepositoryUiIdentity._(
      scope: RepositoryUiIdentityScope.ssh,
      scopeKey: 'ssh:$connectionId',
      gitCommonDir: gitCommonDir,
      durable: true,
    );
  }

  /// Saved local-repo bookmark identity.
  factory RepositoryUiIdentity.local({
    required String localRepoId,
    required String gitCommonDir,
  }) {
    assert(localRepoId.isNotEmpty);
    return RepositoryUiIdentity._(
      scope: RepositoryUiIdentityScope.local,
      scopeKey: 'local:$localRepoId',
      gitCommonDir: gitCommonDir,
      durable: true,
    );
  }

  /// Ad-hoc (unsaved) session identity — never durable.
  factory RepositoryUiIdentity.adhoc({
    required String backend,
    required int sessionEpoch,
    required String gitCommonDir,
  }) {
    assert(sessionEpoch > 0);
    return RepositoryUiIdentity._(
      scope: RepositoryUiIdentityScope.adhoc,
      scopeKey: 'adhoc:$backend:$sessionEpoch',
      gitCommonDir: gitCommonDir,
      durable: false,
      sessionEpoch: sessionEpoch,
    );
  }

  /// When canonical layout cannot be resolved: session-only, never durable.
  factory RepositoryUiIdentity.sessionOnlyUnresolved({
    required String backend,
    required int sessionEpoch,
    required String repoPathFallback,
  }) {
    assert(sessionEpoch > 0);
    return RepositoryUiIdentity._(
      scope: RepositoryUiIdentityScope.adhoc,
      scopeKey: 'adhoc:$backend:$sessionEpoch',
      gitCommonDir: 'unresolved:$repoPathFallback',
      durable: false,
      sessionEpoch: sessionEpoch,
    );
  }

  /// Composite material before encoding (scopeKey + NUL + gitCommonDir).
  String get rawComposite => '$scopeKey\u0000$gitCommonDir';

  /// SharedPreferences-safe key. Prefer only when [durable] is true.
  String get preferenceKey {
    final bytes = utf8.encode(rawComposite);
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// In-memory map key for session-only prefs (includes epoch + common dir).
  String get memoryKey => rawComposite;

  @override
  bool operator ==(Object other) =>
      other is RepositoryUiIdentity &&
      other.scope == scope &&
      other.scopeKey == scopeKey &&
      other.gitCommonDir == gitCommonDir &&
      other.durable == durable &&
      other.sessionEpoch == sessionEpoch;

  @override
  int get hashCode => Object.hash(
    scope,
    scopeKey,
    gitCommonDir,
    durable,
    sessionEpoch,
  );

  @override
  String toString() =>
      'RepositoryUiIdentity($scopeKey, durable=$durable, gitCommonDir=$gitCommonDir)';
}
