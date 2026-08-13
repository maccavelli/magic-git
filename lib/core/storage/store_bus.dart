import 'dart:async';

/// Process-global broadcaster for saved-list changes, so every tab's
/// `savedConnectionsProvider` / `savedLocalReposProvider` (each in its own root
/// [ProviderContainer]) refreshes when any tab writes through [ConnectionStore]
/// or [LocalRepoStore].
///
/// Those providers are per-tab `FutureProvider`s that read disk fresh but only
/// re-run when invalidated; a save/delete in one tab would otherwise leave the
/// other tabs' lists stale. The store write points announce here, and
/// `TabsController` fans out `container.invalidate(...)` to every tab. A plain
/// singleton, same category as [SettingsBus].
class StoreBus {
  StoreBus._();
  static final StoreBus instance = StoreBus._();

  final _connections = StreamController<void>.broadcast();
  final _localRepos = StreamController<void>.broadcast();
  final _recentRepos = StreamController<void>.broadcast();
  final _workspaceSets = StreamController<void>.broadcast();

  /// Fires after any container saves/deletes/updates a saved SSH connection.
  Stream<void> get onConnectionsChanged => _connections.stream;

  /// Fires after any container saves/deletes a saved local repo.
  Stream<void> get onLocalReposChanged => _localRepos.stream;

  /// Fires after any container records a repo open into [RecentReposStore], so
  /// every tab's recent-repos list refreshes.
  Stream<void> get onRecentReposChanged => _recentRepos.stream;

  /// Fires after a named workspace set is saved or deleted.
  Stream<void> get onWorkspaceSetsChanged => _workspaceSets.stream;

  void notifyConnectionsChanged() => _connections.add(null);
  void notifyLocalReposChanged() => _localRepos.add(null);
  void notifyRecentReposChanged() => _recentRepos.add(null);
  void notifyWorkspaceSetsChanged() => _workspaceSets.add(null);
}
