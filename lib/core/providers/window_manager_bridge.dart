import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../exec/exec_proxy_codec.dart';
import '../git/git_service.dart' show GitException;
import '../git/watch_event.dart';
import '../output/output_log.dart';
import '../settings/app_settings.dart';
import '../undo/undo_controller.dart';
import '../undo/undo_journal.dart';
import '../undo/undo_types.dart';
import '../window/window_channels.dart';
import '../window/window_kind.dart';
import 'app_providers.dart';

/// One open secondary window as the main isolate tracks it. The [repoPath] is
/// the repo this window is currently showing; [tabId] is the tab whose container
/// serves it (executor, connection, undo, output).
///
/// A **History** window is a singleton that FOLLOWS the active tab: [tabId] is
/// re-pointed to whichever tab is active (see `onActiveTabChanged`) so the
/// pop-out always mirrors the repo the user is currently looking at. A
/// repo-bound (detached) window instead stays pinned to its spawning tab.
class WindowHandle {
  final String id;
  final WindowKind kind;
  final String? repoPath;
  final String? tabId;

  const WindowHandle({
    required this.id,
    required this.kind,
    this.repoPath,
    this.tabId,
  });

  WindowHandle withRepoPath(String? path) =>
      WindowHandle(id: id, kind: kind, repoPath: path, tabId: tabId);
}

/// Main-isolate registry and hub for every native secondary window: mints
/// window ids, opens/closes/fronts windows (via the Swift `magicgit/windows`
/// control channel), serves each window's proxied git commands and side effects
/// over its own per-window hub channel, and fans session/watcher/settings
/// events out to the windows they concern.
///
/// It is a **single process-global instance** living in the root
/// [ProviderScope] container — NOT per tab — because the native
/// `magicgit/windows` control handler and the `id`/hub registry are last-wins
/// and must not be duplicated across tab containers. Each open window is pinned
/// to its spawning tab ([WindowHandle.tabId]); the bridge resolves that tab's
/// [ProviderContainer] through [sessionContainerFor] (wired by `TabsHost`) and
/// reads/subscribes session state there. Reached from tab-land (which lives in
/// separate root containers with no path to this provider) via [current].
///
/// Ids are minted HERE and each window's hub handler is installed BEFORE
/// `openWindow` is invoked, so a child's first `requestState`/event can never
/// race an unregistered handler.
class WindowManagerBridge extends Notifier<List<WindowHandle>> {
  static const _control = MethodChannel(windowControlChannel);

  /// The live bridge while its provider is alive. Tab widgets (AppShell,
  /// TabsHost) reach it through this instead of `ref` — their tab containers are
  /// separate roots that don't contain this provider, so watching it there would
  /// spin up a second, conflicting bridge.
  static WindowManagerBridge? current;

  /// Resolves the [ProviderContainer] for a spawning tab id — wired by TabsHost
  /// to `TabsController.containerFor`. Returns null when the tab has since
  /// closed (its window is on the way out) or before any host is mounted.
  ProviderContainer? Function(String? tabId) sessionContainerFor = (_) => null;

  /// The id of the currently active tab — wired by TabsHost. A pop-out is always
  /// spawned from the active tab (only its AppShell is mounted), so this is the
  /// tab a new window pins to.
  String? Function() activeTabId = () => null;

  /// Resolves the container of the open tab that owns [repoPath] — wired by
  /// TabsHost to `TabsController.containerForRepo`. Proxied `execute` calls route
  /// by the repo in the REQUEST (which the child always knows), not the pinned
  /// tab, so a command can never hit the wrong session while a History pop-out
  /// is mid-switch between repos.
  ProviderContainer? Function(String repoPath) containerForRepo = (_) => null;

  /// Per-window hub channels, keyed by window id — one handler installed per
  /// open window, torn down when it closes.
  final Map<String, MethodChannel> _hubs = {};

  /// Per-window subscription to its pinned tab's connection — drives
  /// connectionChanged pushes, history retargeting, and close-on-disconnect.
  final Map<String, ProviderSubscription<ConnectionState>> _connSubs = {};

  /// Per-History-window subscription that waits for a just-switched-to tab to
  /// finish connecting before retargeting the follower onto it (a freshly
  /// opened repo tab is activated synchronously but connects a beat later).
  final Map<String, ProviderSubscription<ConnectionState>> _pendingSubs = {};

  /// Per-window subscription to its pinned tab's file watcher for the repo it
  /// shows — forwards ticks so the window refreshes even while its tab is
  /// backgrounded. Re-pointed when a history window retargets.
  final Map<String, ProviderSubscription<AsyncValue<RepoWatchEvent>>>
  _tickSubs = {};

  int _nextId = 1;

  @override
  List<WindowHandle> build() {
    current = this;
    _control.setMethodCallHandler(_onControlCall);
    ref.onDispose(() {
      if (identical(current, this)) current = null;
      _control.setMethodCallHandler(null);
      for (final s in _connSubs.values) {
        s.close();
      }
      for (final s in _tickSubs.values) {
        s.close();
      }
      for (final s in _pendingSubs.values) {
        s.close();
      }
      _connSubs.clear();
      _tickSubs.clear();
      _pendingSubs.clear();
      for (final hub in _hubs.values) {
        hub.setMethodCallHandler(null);
      }
      _hubs.clear();
    });
    // Each isolate caches SharedPreferences independently; a settings edit here
    // (committer identity, timeouts, zoom) must tell every open window to
    // reload or its GitService keeps the stale snapshot until reopen. Settings
    // are global (bus-synced across tab containers), so this reads the bridge's
    // own (root) container — no per-tab routing needed.
    ref.listen(appSettingsProvider, (_, _) => _broadcast('settingsChanged'));
    return const [];
  }

  WindowHandle? _handle(String id) {
    for (final w in state) {
      if (w.id == id) return w;
    }
    return null;
  }

  /// Opens (or fronts) the History window for the active tab — mirrors that
  /// tab's session repo. No-op unless the active tab has a repo active.
  Future<void> openHistory() =>
      _open(WindowKind.history, null, activeTabId());

  /// Opens (or fronts) a detached full-repo window pinned to [repoPath] on the
  /// active tab. Falls back to that tab's active repo when [repoPath] is null.
  Future<void> openDetachedRepo([String? repoPath]) =>
      _open(WindowKind.detachedRepo, repoPath, activeTabId());

  Future<void> _open(WindowKind kind, String? repoPath, String? tabId) async {
    final container = sessionContainerFor(tabId);
    if (container == null) {
      _debugLog('open gated: no session container for tab=$tabId');
      return;
    }
    final connection = container.read(connectionProvider);
    if (!connection.isConnected) {
      _debugLog('open gated: phase=${connection.phase.name}');
      return;
    }
    // History follows the active repo; a repo-bound kind pins the one given (or
    // the active one). Either way a target repo must exist.
    final target = kind.isSingleton
        ? connection.repoPath
        : (repoPath ?? connection.repoPath);
    if (target == null) {
      _debugLog('open gated: no repo');
      return;
    }

    // History is a singleton (one window that follows the active tab); a
    // repo-bound window dedupes on its pinned (tab, repo).
    final existing = _existingForTab(kind, target, tabId);
    if (existing != null) {
      _debugLog('open: fronting existing ${kind.name} ${existing.id}');
      await _invokeControl('frontWindow', {'windowId': existing.id});
      return;
    }

    final id = (_nextId++).toString();
    // Install this window's hub handler BEFORE asking native to open it, so the
    // child's first requestState/undoRecord can never find a missing handler.
    final hub = MethodChannel(windowHubChannel(id));
    hub.setMethodCallHandler((call) => _onHubCall(id, call));
    _hubs[id] = hub;
    final handle = WindowHandle(
      id: id,
      kind: kind,
      repoPath: target,
      tabId: tabId,
    );
    // Optimistic registry add — the authoritative "still open" signal is the
    // native windowClosed notification, which removes it again.
    state = [...state, handle];
    _subscribeWindow(id, container, target);

    try {
      _debugLog('open: ${kind.name} id=$id repo=$target tab=$tabId');
      await _invokeControl('openWindow', {
        'windowId': id,
        'kind': kind.name,
        'repoPath': target,
        'title': _titleFor(handle, connection),
        'connectionLabel': connection.connectionLabel,
      });
    } catch (e) {
      // Missing handler / platform error — the window didn't open; roll back so
      // events aren't pushed into the void.
      _debugLog('open failed: $e');
      _forget(id);
    }
  }

  WindowHandle? _existingForTab(WindowKind kind, String? repoPath, String? tabId) {
    for (final w in state) {
      if (w.kind != kind) continue;
      // A singleton (History) fronts the one existing window regardless of which
      // tab it's currently following; a repo-bound window is per (tab, repo).
      if (kind.isSingleton) return w;
      if (w.tabId == tabId && w.repoPath == repoPath) return w;
    }
    return null;
  }

  /// The active tab changed — retarget every follow-active (History) window so
  /// the pop-out mirrors whichever repo the user is now looking at. [isBlank] is
  /// whether the new active tab is a blank landing tab (no repo, and none
  /// pending) — the bridge can't tell that from the container alone, because a
  /// freshly-opened repo tab is *also* momentarily disconnected: it's activated
  /// synchronously but its connect runs a beat later. So:
  ///  - already connected with a repo → retarget now;
  ///  - a repo tab still connecting → keep the window where it is and retarget
  ///    once that tab reports its repo (the [_pendingSubs] wait) — this is what
  ///    stops a brand-new repo from closing the window;
  ///  - a genuine blank landing tab → close the follower only if the repo it's
  ///    currently showing is gone (its tab was closed); otherwise leave it
  ///    (the user is just visiting the landing between repos).
  /// Called by TabsHost on every active-tab switch.
  void onActiveTabChanged(String? tabId, {required bool isBlank}) {
    if (state.every((w) => w.kind != WindowKind.history)) return;
    final container = tabId == null ? null : sessionContainerFor(tabId);
    final conn = container?.read(connectionProvider);
    final ready = conn != null && conn.isConnected && conn.repoPath != null;
    for (final w in List<WindowHandle>.of(state)) {
      if (w.kind != WindowKind.history) continue;
      _pendingSubs.remove(w.id)?.close();
      if (ready) {
        // Already following this exact tab+repo — skip the repin so a redundant
        // call (e.g. the explicit re-home from TabsController.close when a
        // non-active followed tab is closed, which fires alongside TabsHost's
        // own activeId-changed retarget) doesn't re-push a snapshot and force
        // the child to needlessly refetch.
        if (w.tabId == tabId && w.repoPath == conn.repoPath) continue;
        _repinHistory(w.id, tabId!, container!, conn);
      } else if (!isBlank && container != null && tabId != null) {
        // A repo tab mid-connect — wait for it, then retarget (if it's still
        // the active tab by the time it connects).
        final pendingTab = tabId;
        final pendingContainer = container;
        _pendingSubs[w.id] = pendingContainer.listen(connectionProvider, (
          _,
          next,
        ) {
          if (next.isConnected &&
              next.repoPath != null &&
              activeTabId() == pendingTab) {
            _pendingSubs.remove(w.id)?.close();
            _repinHistory(w.id, pendingTab, pendingContainer, next);
          }
        });
      } else if (sessionContainerFor(w.tabId) == null) {
        // Blank landing tab AND the repo this window was showing is gone.
        close(w.id);
      }
    }
  }

  /// Re-pins a History window onto [tabId]/[container]: swaps its tabId+repo,
  /// moves its connection/watcher subscriptions, and pushes the new snapshot so
  /// the child refetches for the new repo.
  void _repinHistory(
    String windowId,
    String tabId,
    ProviderContainer container,
    ConnectionState conn,
  ) {
    final updated = WindowHandle(
      id: windowId,
      kind: WindowKind.history,
      repoPath: conn.repoPath,
      tabId: tabId,
    );
    state = [
      for (final x in state)
        if (x.id == windowId) updated else x,
    ];
    _connSubs.remove(windowId)?.close();
    _connSubs[windowId] = container.listen(
      connectionProvider,
      (_, next) => _onWindowConnectionChanged(windowId, next),
    );
    _subscribeTick(windowId, container, conn.repoPath);
    _hubs[windowId]
        ?.invokeMethod<void>(
          'connectionChanged',
          _snapshotFor(updated, conn).encode(),
        )
        .catchError((_) {});
  }

  /// Subscribes a freshly-opened window to its pinned tab's connection + file
  /// watcher.
  void _subscribeWindow(
    String id,
    ProviderContainer container,
    String? repoPath,
  ) {
    _connSubs[id] = container.listen(
      connectionProvider,
      (_, next) => _onWindowConnectionChanged(id, next),
    );
    _subscribeTick(id, container, repoPath);
  }

  void _subscribeTick(
    String id,
    ProviderContainer container,
    String? repoPath,
  ) {
    _tickSubs.remove(id)?.close();
    if (repoPath == null) return;
    _tickSubs[id] = container.listen(repoWatchProvider(repoPath), (_, next) {
      final event = next.value;
      if (event != null) forwardTick(repoPath, event);
    });
  }

  /// Closes a specific window (used by explicit UI close and disconnect).
  Future<void> close(String id) async {
    try {
      await _invokeControl('closeWindow', {'windowId': id});
    } on PlatformException {
      // Already gone.
    }
  }

  /// A tab is closing (its container is about to be disposed). A repo-bound
  /// window pinned to it goes away with it. A History follower currently showing
  /// this tab is NOT closed — it follows the active tab, and closing this one
  /// makes a neighbor active — so just detach its now-dangling subscriptions
  /// from the departing container; the ensuing `onActiveTabChanged` re-pins it
  /// (or closes it if no repo tab remains active). Called by TabsController.close
  /// before the container is disposed.
  void onTabClosed(String tabId) {
    for (final w in List<WindowHandle>.of(state)) {
      if (w.tabId != tabId) continue;
      if (w.kind == WindowKind.history) {
        _connSubs.remove(w.id)?.close();
        _tickSubs.remove(w.id)?.close();
        _pendingSubs.remove(w.id)?.close();
      } else {
        close(w.id);
        _forget(w.id);
      }
    }
  }

  /// Removes a window from the registry and tears down its hub handler and
  /// subscriptions. Called on the native `windowClosed` notification, a failed
  /// open, and tab close.
  void _forget(String id) {
    _connSubs.remove(id)?.close();
    _tickSubs.remove(id)?.close();
    _pendingSubs.remove(id)?.close();
    _hubs.remove(id)?.setMethodCallHandler(null);
    if (state.any((w) => w.id == id)) {
      state = [
        for (final w in state)
          if (w.id != id) w,
      ];
    }
  }

  /// ⌘R parity: called from AppShell's refresh so a manual refresh covers every
  /// open window showing [repoPath].
  void invalidateAllFor(String repoPath) {
    for (final w in state) {
      if (w.repoPath == repoPath) {
        _hubs[w.id]?.invokeMethod<void>('invalidateAll', {
          'repoPath': repoPath,
        }).catchError((_) {});
      }
    }
  }

  /// Forwards one watcher tick to every window showing [repoPath]. Deliberately
  /// unsuppressed — each window applies its own own-mutation logic.
  void forwardTick(String repoPath, RepoWatchEvent event) {
    final payload = {
      'repoPath': repoPath,
      'mode': event.mode.name,
      'atMs': event.at.millisecondsSinceEpoch,
      // Carried across the isolate boundary so a pop-out window can scope its
      // refresh the same way the main one does. An empty list means the tick's
      // scope is unknown (poll/restart), not that nothing changed — see
      // [RepoWatchEvent.paths].
      'paths': event.paths.toList(),
    };
    for (final w in state) {
      if (w.repoPath == repoPath) {
        _hubs[w.id]?.invokeMethod<void>('repoTick', payload).catchError((_) {});
      }
    }
  }

  Future<Object?> _onControlCall(MethodCall call) async {
    if (call.method == 'windowClosed') {
      final id = (call.arguments as Map?)?['windowId'] as String?;
      if (id != null) _forget(id);
    }
    return null;
  }

  /// A pinned tab's connection changed: retarget a history window to follow that
  /// tab's repo, push the new snapshot to the window, and close it if the tab's
  /// session ended.
  void _onWindowConnectionChanged(String id, ConnectionState next) {
    final handle = _handle(id);
    if (handle == null) return;
    final disconnected = next.phase == ConnectionPhase.disconnected;
    // A History window retargets to follow its tab's active repo; a repo-bound
    // window keeps its pinned repo across session changes.
    final updated = handle.kind == WindowKind.history && next.isConnected
        ? _retarget(handle, next.repoPath)
        : handle;
    // Retargeted → move the watcher subscription to the new repo.
    if (!identical(updated, handle)) {
      final container = sessionContainerFor(handle.tabId);
      if (container != null) _subscribeTick(id, container, updated.repoPath);
    }
    _hubs[id]
        ?.invokeMethod<void>(
          'connectionChanged',
          _snapshotFor(updated, next).encode(),
        )
        .catchError((_) {});
    if (disconnected) {
      // The window follows the session — close it. The child also asks Swift to
      // close on seeing a disconnected snapshot; both paths are idempotent.
      close(id);
    }
  }

  WindowHandle _retarget(WindowHandle handle, String? repoPath) {
    if (handle.repoPath == repoPath) return handle;
    final next = handle.withRepoPath(repoPath);
    state = [
      for (final w in state)
        if (w.id == handle.id) next else w,
    ];
    return next;
  }

  ConnectionEventPayload _snapshotFor(WindowHandle handle, ConnectionState c) =>
      ConnectionEventPayload(
        phase: c.phase.name,
        backend: c.backend.name,
        // The window's OWN repo — a detached window stays pinned regardless of
        // which repo is active in its tab.
        repoPath: handle.repoPath,
        connectionLabel: c.connectionLabel,
        host: c.host,
      );

  String _titleFor(WindowHandle handle, ConnectionState c) {
    final repoName = handle.repoPath?.split('/').last;
    final prefix = handle.kind == WindowKind.history ? 'History' : 'Repo';
    if (repoName == null) return prefix;
    final label = c.connectionLabel == null ? '' : ' (${c.connectionLabel})';
    return '$prefix — $repoName$label';
  }

  /// Serves one call from window [id]'s child isolate against the window's
  /// PINNED tab container. If that tab has since closed there's no container to
  /// serve from — reply-expecting methods raise `RELAY_DOWN` (the child treats
  /// it as "window on its way out"); fire-and-forget ones are dropped.
  Future<Object?> _onHubCall(String id, MethodCall call) async {
    final handle = _handle(id);
    final container = handle == null ? null : sessionContainerFor(handle.tabId);
    switch (call.method) {
      case 'execute':
        final request = decodeExecuteRequest(
          call.arguments as Map<Object?, Object?>,
        );
        // Resolve the session to run this on by the repo in the REQUEST (the
        // child always knows its repo), not blindly by the pinned tab:
        //  - prefer the pinned tab when its live session actually OWNS the repo
        //    — this pins to the right host when the same path is open on two
        //    connections, and is the normal fast path;
        //  - otherwise the (first) open tab that holds the repo — this routes a
        //    follow-active window's lagging request for the PREVIOUS repo to
        //    whichever tab still has it, mid-switch;
        //  - otherwise no live session owns the repo (its tab closed) → RELAY_DOWN.
        // Crucially there is NO "fall back to the pinned tab regardless" branch:
        // running `git -C <repo>` against a session that doesn't own it would hit
        // the wrong host (or silently the wrong repo). RELAY_DOWN is the safe end.
        final execContainer = _execContainerFor(container, request.repoPath);
        if (execContainer == null) throw _relayDown();
        try {
          // Read per call so a backend switch mid-session is honored.
          final result = await execContainer.read(activeExecutorProvider).execute(
            repoPath: request.repoPath,
            gitArgs: request.gitArgs,
            extraEnv: request.extraEnv,
            stdin: request.stdin,
            timeout: request.timeout,
            retries: request.retries,
            lane: request.lane,
            compress: request.compress,
          );
          return encodeExecuteResult(result);
        } catch (e) {
          // Typed executor exceptions keep their identity across the wire;
          // everything else degrades to a message. Never let a throw escape
          // into the channel as an opaque PlatformException.
          return encodeExecuteError(e);
        }
      case 'requestState':
        if (container == null) throw _relayDown();
        final resolved =
            handle ??
            WindowHandle(
              id: id,
              kind: WindowKind.history,
              repoPath: container.read(connectionProvider).repoPath,
            );
        return _snapshotFor(
          resolved,
          container.read(connectionProvider),
        ).encode();
      case 'undoRecord':
        if (container == null) return null;
        final record = UndoRecord.fromJson(
          call.arguments as Map<Object?, Object?>,
        );
        // A null record means version skew — drop it. Mark it as window-
        // originated first so the main window's journal-driven UndoToastOverlay
        // stays silent — the originating window already showed its own toast.
        if (record != null) {
          container.read(historyOriginUndoProvider.notifier).mark(record);
          container.read(undoJournalProvider.notifier).push(record);
        }
        return null;
      case 'performUndo':
        if (container == null) throw _relayDown();
        // ⌘Z pressed in a secondary window. The journal (and the executor that
        // can safely run the undo script) live in the pinned tab; all
        // user-facing UI for the outcome renders back in that window from the
        // reply, so `force` only ever arrives after a user confirmed there.
        final args = call.arguments as Map<Object?, Object?>;
        final repoPath = args['repoPath'] as String?;
        if (repoPath == null) return {'status': UndoStatus.nothingToUndo.name};
        try {
          final attempt = await container
              .read(undoControllerProvider)
              .undo(repoPath, force: args['force'] == true);
          final description = attempt.record?.description;
          if (attempt.status == UndoStatus.done) {
            container
                .read(outputLogProvider.notifier)
                .logInfo('Undid: $description');
          }
          return {'status': attempt.status.name, 'description': ?description};
        } on GitException catch (e) {
          return {'status': 'error', 'message': '$e'};
        } catch (e) {
          return {'status': 'error', 'message': 'Undo failed: $e'};
        }
      case 'settingsChanged':
        // A window persisted a settings edit; adopt it here (each isolate
        // caches its own SharedPreferences). Settings are global, so this is the
        // bridge's own (root) container — the echo terminates because a
        // same-value reload re-broadcasts nothing new.
        await ref.read(appSettingsProvider.notifier).reloadFromDisk();
        return null;
      case 'mutationPerformed':
        if (container == null) return null;
        final repoPath =
            (call.arguments as Map<Object?, Object?>)['repoPath'] as String?;
        if (repoPath != null) {
          // Same refresh contract as a local mutation call site: mark so the
          // watcher echo is suppressed, bump the edit generation, and refresh
          // what a mutation can change — in the pinned tab's container.
          container.read(ownMutationTrackerProvider).mark(repoPath);
          container.read(worktreeEditsProvider.notifier).noteRepo(repoPath);
          for (final p in repoMutationFamilies(repoPath)) {
            container.invalidate(p);
          }
        }
        return null;
    }
    return null;
  }

  /// Picks the session container to run a proxied `execute` for [repoPath] on.
  /// See the routing comment in `_onHubCall`. Prefers [pinned] when its session
  /// owns the repo, else any open tab that holds it, else null (RELAY_DOWN).
  ProviderContainer? _execContainerFor(
    ProviderContainer? pinned,
    String repoPath,
  ) {
    if (pinned != null && _sessionOwns(pinned, repoPath)) return pinned;
    return containerForRepo(repoPath);
  }

  /// Whether [container]'s live connection currently serves [repoPath] — its
  /// active repo or one of the connection's known repos (a single host can hold
  /// several). Used to keep a command on the session that actually owns its repo.
  bool _sessionOwns(ProviderContainer container, String repoPath) {
    final conn = container.read(connectionProvider);
    return conn.repoPath == repoPath || conn.repoPaths.contains(repoPath);
  }

  PlatformException _relayDown() => PlatformException(
    code: 'RELAY_DOWN',
    message: 'the window\'s tab has closed',
  );

  /// Broadcasts a fire-and-forget event (no args) to every open window.
  void _broadcast(String method) {
    for (final hub in _hubs.values) {
      hub.invokeMethod<void>(method, null).catchError((_) {});
    }
  }

  Future<void> _invokeControl(String method, Object? arguments) =>
      _control.invokeMethod<void>(method, arguments);

  /// Ships a diagnostic line to the unified log via Swift (NSLog) — the only
  /// place release-build Dart prints are visible when launched from Finder.
  void _debugLog(String message) {
    _control.invokeMethod<void>('debugLog', message).catchError((_) {});
  }
}

final windowManagerBridgeProvider =
    NotifierProvider<WindowManagerBridge, List<WindowHandle>>(
      WindowManagerBridge.new,
    );

/// Whether the History window is currently open — the toolbar/menu toggle state.
final historyWindowOpenProvider = Provider<bool>((ref) {
  final windows = ref.watch(windowManagerBridgeProvider);
  return windows.any((w) => w.kind == WindowKind.history);
});
