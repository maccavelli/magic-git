import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;

import '../exec/local_command_executor.dart';
import '../providers/app_providers.dart';
import '../ssh/ssh_client_manager.dart';

/// The session-seam overrides that make a tab's [ProviderContainer] its own
/// isolated session: a fresh connection controller, SSH client, and local
/// executor. Everything downstream — `activeExecutorProvider`, the git/glab/gh
/// services, and every `dependencies`-annotated repo family — recomputes against
/// these *inside* the tab container (proven by `tab_scope_isolation_test`), so a
/// tab's commands, caches, watcher, and auth never touch another tab's.
///
/// Only these three transport roots need overriding; the annotated graph scopes
/// off them automatically. Connection-scoped extras that must also become
/// per-tab for full cross-connection isolation (binaryEnvironment, ping samples,
/// per-tab output/visibility channels) are layered in by later tab phases.
List<Override> sessionOverridesFor() => [
  connectionProvider.overrideWith(ConnectionController.new),
  sshClientManagerProvider.overrideWith((ref) {
    final manager = SSHClientManager();
    ref.onDispose(manager.disconnect);
    return manager;
  }),
  localExecutorProvider.overrideWith((ref) => LocalCommandExecutor()),
];

/// One open repository tab: a stable id, its own child [ProviderContainer]
/// (parented to the app root so shared providers — settings, keymap, stores, the
/// multi-window bridge — stay single-instance), and display metadata for the tab
/// strip. The container owns the tab's whole session; disposing it tears the
/// session (and its SSH socket, via [sessionOverridesFor]'s onDispose) down.
class RepoTab {
  RepoTab({
    required this.id,
    required this.container,
    this.title = '',
    this.connectionId,
    this.repoPath,
  });

  final String id;
  final ProviderContainer container;
  String title;
  String? connectionId;
  String? repoPath;
}

/// Owns the set of open tabs and the active one. Deliberately a plain
/// [ChangeNotifier], not a Riverpod provider: the per-tab [ProviderContainer]s
/// are imperative resources (created, parented to root, disposed), not reactive
/// state, and managing them outside Riverpod keeps that lifecycle explicit. The
/// reactive surface the UI needs — the tab list + active id — rides this
/// notifier. Exposed to the tree via a plain provider override of
/// [tabsControllerProvider] set up at app bootstrap.
class TabsController extends ChangeNotifier {
  TabsController(this._root);

  /// The app-root container every tab container is parented to, so shared
  /// (non-`dependencies`) providers resolve to one instance across all tabs.
  final ProviderContainer _root;

  final List<RepoTab> _tabs = [];
  String? _activeId;
  int _nextId = 1;

  List<RepoTab> get tabs => List.unmodifiable(_tabs);
  String? get activeId => _activeId;
  RepoTab? get active => _activeId == null ? null : _byId(_activeId!);
  bool get isEmpty => _tabs.isEmpty;

  /// Opens the existing tab for [connectionId]/[repoPath] if one is already
  /// open (focuses it), else creates a fresh isolated tab and activates it.
  /// Dedupe is by `(connectionId, repoPath)` so re-selecting an open repo never
  /// spawns a duplicate session.
  RepoTab openOrFocus({
    String? connectionId,
    String? repoPath,
    String title = '',
  }) {
    final existing = _find(connectionId, repoPath);
    if (existing != null) {
      activate(existing.id);
      return existing;
    }
    final tab = RepoTab(
      id: 'tab-${_nextId++}',
      container: ProviderContainer(
        parent: _root,
        overrides: sessionOverridesFor(),
      ),
      title: title,
      connectionId: connectionId,
      repoPath: repoPath,
    );
    _tabs.add(tab);
    _activeId = tab.id;
    notifyListeners();
    return tab;
  }

  void activate(String id) {
    if (_activeId == id || _byId(id) == null) return;
    _activeId = id;
    notifyListeners();
  }

  /// Closes a tab: disposes its container (which disconnects its session), then
  /// activates a neighbor (or clears the active id when the last tab closes).
  void closeTab(String id) {
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final tab = _tabs.removeAt(index);
    if (_activeId == id) {
      _activeId = _tabs.isEmpty
          ? null
          : _tabs[index < _tabs.length ? index : _tabs.length - 1].id;
    }
    tab.container.dispose();
    notifyListeners();
  }

  RepoTab? _byId(String id) {
    for (final t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  RepoTab? _find(String? connectionId, String? repoPath) {
    for (final t in _tabs) {
      if (t.connectionId == connectionId && t.repoPath == repoPath) return t;
    }
    return null;
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.container.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}

/// Handle to the app's [TabsController]. Overridden with the real instance at
/// bootstrap (it needs the root container reference, which only exists then);
/// the default throws so a missing override is loud rather than silently wrong.
final tabsControllerProvider = Provider<TabsController>(
  (ref) => throw StateError('tabsControllerProvider must be overridden'),
);
