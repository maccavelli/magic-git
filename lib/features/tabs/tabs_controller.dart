import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;

import '../../core/providers/app_providers.dart';
import '../../core/storage/store_bus.dart';

/// One open repository tab: a stable id and its OWN root [ProviderContainer].
///
/// Because the container is a fresh **root** (no parent), the entire session +
/// repo + family graph resolves locally inside it — each tab is a complete,
/// isolated session with zero changes to the provider definitions and no
/// `dependencies` scoping. `container.dispose()` fires
/// `sshClientManagerProvider`'s `onDispose(disconnect)`.
///
/// [connectionId]/[repoPath] are the dedupe key (kept in sync with the tab's
/// live connection); a blank landing tab has both null.
class RepoTab {
  RepoTab({required this.id, required this.container});

  final String id;
  final ProviderContainer container;
  String? connectionId;
  String? repoPath;
  ProviderSubscription<ConnectionState>? _connSub;

  bool get isBlank => connectionId == null && repoPath == null;
}

/// Owns the set of open tabs and the active one. A plain [ChangeNotifier] (not a
/// Riverpod provider): the per-tab [ProviderContainer]s are imperative resources
/// (created, disposed), not reactive provider state. Exposed to the tree via
/// [TabsScope]; created once at app bootstrap.
class TabsController extends ChangeNotifier {
  TabsController({ProviderContainer Function(List<Override> overrides)? containerFactory})
    : _containerFactory =
          containerFactory ?? _defaultContainerFactory {
    // Any tab's saved-list write refreshes every tab's list (each tab reads
    // disk in its own container, so a write elsewhere would otherwise go
    // unseen). recentWorkspacesProvider derives from these, so it follows.
    _storeSubs.add(
      StoreBus.instance.onConnectionsChanged.listen((_) {
        for (final t in _tabs) {
          t.container.invalidate(savedConnectionsProvider);
        }
      }),
    );
    _storeSubs.add(
      StoreBus.instance.onLocalReposChanged.listen((_) {
        for (final t in _tabs) {
          t.container.invalidate(savedLocalReposProvider);
        }
      }),
    );
  }

  static ProviderContainer _defaultContainerFactory(List<Override> overrides) =>
      ProviderContainer(retry: (_, _) => null, overrides: overrides);

  final ProviderContainer Function(List<Override>) _containerFactory;
  final List<StreamSubscription<void>> _storeSubs = [];
  final List<RepoTab> _tabs = [];
  String? _activeId;
  int _nextId = 1;

  List<RepoTab> get tabs => List.unmodifiable(_tabs);
  String? get activeId => _activeId;
  RepoTab? get active => _activeId == null ? null : _byId(_activeId!);
  ProviderContainer? containerFor(String id) => _byId(id)?.container;

  /// Ensures at least one (blank, disconnected) tab exists — it shows the
  /// landing screen. Called at boot and whenever the last tab closes.
  RepoTab ensureInitialTab() => _tabs.isEmpty ? _create() : active!;

  /// Opens (or focuses) a tab for [connectionId]/[repoPath] and connects it.
  /// Dedupe: a matching open tab is focused, not duplicated. A blank landing
  /// tab (the active one, never targeted) is reused instead of left empty.
  /// [connect] runs against the TARGET tab's own container.
  RepoTab openOrFocus({
    String? connectionId,
    String? repoPath,
    List<Override> overrides = const [],
    required void Function(ProviderContainer container) connect,
  }) {
    final existing = _find(connectionId, repoPath);
    if (existing != null) {
      activate(existing.id);
      return existing;
    }
    final act = active;
    if (act != null && act.isBlank) {
      act.connectionId = connectionId;
      act.repoPath = repoPath;
      connect(act.container);
      notifyListeners();
      return act;
    }
    final tab = _create(
      connectionId: connectionId,
      repoPath: repoPath,
      overrides: overrides,
    );
    connect(tab.container);
    return tab;
  }

  void activate(String id) {
    if (_activeId == id || _byId(id) == null) return;
    _activeId = id;
    notifyListeners();
  }

  /// Closes a tab: gracefully disconnects its session (clean SSH bye / env
  /// reset), then disposes its container. Re-activates a neighbor; if it was the
  /// last tab, opens a fresh blank one so the app always has a landing tab.
  Future<void> close(String id) async {
    final idx = _tabs.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final tab = _tabs.removeAt(idx);
    final wasActive = _activeId == id;
    tab._connSub?.close();
    try {
      await tab.container.read(connectionProvider.notifier).disconnect();
    } catch (_) {
      // Best-effort — a disconnect hiccup must not block teardown.
    }
    tab.container.dispose();
    if (wasActive) {
      _activeId = _tabs.isEmpty
          ? null
          : _tabs[idx < _tabs.length ? idx : _tabs.length - 1].id;
    }
    if (_tabs.isEmpty) {
      _create(); // keep >=1 tab (a blank landing tab)
    } else {
      notifyListeners();
    }
  }

  RepoTab _create({
    String? connectionId,
    String? repoPath,
    List<Override> overrides = const [],
  }) {
    final tab = RepoTab(
      id: 'tab-${_nextId++}',
      container: _containerFactory(overrides),
    )
      ..connectionId = connectionId
      ..repoPath = repoPath;
    // Keep the dedupe key in sync with the tab's live session.
    tab._connSub = tab.container.listen(connectionProvider, (_, next) {
      tab.connectionId = next.connectionId;
      tab.repoPath = next.repoPath;
      notifyListeners();
    });
    _tabs.add(tab);
    _activeId = tab.id;
    notifyListeners();
    return tab;
  }

  RepoTab? _byId(String id) {
    for (final t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  RepoTab? _find(String? connectionId, String? repoPath) {
    // Never match a blank tab (both null) — that's the landing tab, handled by
    // reuse in openOrFocus, not dedupe.
    if (connectionId == null && repoPath == null) return null;
    for (final t in _tabs) {
      if (t.connectionId == connectionId && t.repoPath == repoPath) return t;
    }
    return null;
  }

  @override
  void dispose() {
    for (final s in _storeSubs) {
      s.cancel();
    }
    for (final t in _tabs) {
      t._connSub?.close();
      t.container.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}
