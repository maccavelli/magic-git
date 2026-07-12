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
/// the repo this window is currently showing: for a [WindowKind.history] window
/// it tracks the active session's repo (updated as the session switches); for a
/// repo-bound kind it is fixed for the window's life.
class WindowHandle {
  final String id;
  final WindowKind kind;
  final String? repoPath;

  const WindowHandle({required this.id, required this.kind, this.repoPath});

  WindowHandle withRepoPath(String? path) =>
      WindowHandle(id: id, kind: kind, repoPath: path);
}

/// Main-isolate registry and hub for every native secondary window: mints
/// window ids, opens/closes/fronts windows (via the Swift `magicgit/windows`
/// control channel), serves each window's proxied git commands and side effects
/// over its own per-window hub channel, and fans session/watcher/settings
/// events out to the windows they concern.
///
/// State is the list of open windows. Ids are minted HERE (not natively) and
/// each window's hub handler is installed BEFORE `openWindow` is invoked, so a
/// child's first `requestState`/event can never race an unregistered handler —
/// and the bridge is unit-testable with a known id, no native side required.
/// Native owns only the NSWindow/engine map, keyed by the id we hand it.
///
/// Dedupe lives here too (the registry is here): a [WindowKind.isSingleton]
/// window fronts the existing one; a repo-bound kind fronts the existing window
/// for the same `(kind, repoPath)`. The native side stays a dumb executor of
/// open/close/front by id.
class WindowManagerBridge extends Notifier<List<WindowHandle>> {
  static const _control = MethodChannel(windowControlChannel);

  /// Per-window hub channels, keyed by window id — one handler installed per
  /// open window, torn down when it closes.
  final Map<String, MethodChannel> _hubs = {};
  int _nextId = 1;

  @override
  List<WindowHandle> build() {
    _control.setMethodCallHandler(_onControlCall);
    ref.onDispose(() {
      _control.setMethodCallHandler(null);
      for (final hub in _hubs.values) {
        hub.setMethodCallHandler(null);
      }
      _hubs.clear();
    });
    ref.listen(connectionProvider, _onConnectionChanged);
    // Each isolate caches SharedPreferences independently; a settings edit here
    // (committer identity, timeouts, zoom) must tell every open window to
    // reload or its GitService keeps the stale snapshot until reopen.
    ref.listen(appSettingsProvider, (_, _) => _broadcast('settingsChanged'));
    return const [];
  }

  WindowHandle? _handle(String id) {
    for (final w in state) {
      if (w.id == id) return w;
    }
    return null;
  }

  WindowHandle? _existing(WindowKind kind, String? repoPath) {
    for (final w in state) {
      if (w.kind != kind) continue;
      if (kind.isSingleton || w.repoPath == repoPath) return w;
    }
    return null;
  }

  /// Opens (or fronts) the History window — mirrors the active session's repo.
  /// No-op unless a repo is active; the window is a client of the live session.
  Future<void> openHistory() => _open(WindowKind.history, null);

  /// Opens (or fronts) a detached full-repo window pinned to [repoPath]. Falls
  /// back to the active repo when [repoPath] is null.
  Future<void> openDetachedRepo([String? repoPath]) =>
      _open(WindowKind.detachedRepo, repoPath);

  Future<void> _open(WindowKind kind, String? repoPath) async {
    final connection = ref.read(connectionProvider);
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

    final existing = _existing(kind, target);
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
    final handle = WindowHandle(id: id, kind: kind, repoPath: target);
    // Optimistic registry add — the authoritative "still open" signal is the
    // native windowClosed notification, which removes it again.
    state = [...state, handle];

    try {
      _debugLog('open: ${kind.name} id=$id repo=$target');
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

  /// Closes a specific window (used by explicit UI close and disconnect).
  Future<void> close(String id) async {
    try {
      await _invokeControl('closeWindow', {'windowId': id});
    } on PlatformException {
      // Already gone.
    }
  }

  /// Removes a window from the registry and tears down its hub handler. Called
  /// on the native `windowClosed` notification and on a failed open.
  void _forget(String id) {
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

  /// Forwards one watcher tick to every window showing [repoPath] (subscription
  /// owned by [windowTickForwardersProvider]). Deliberately unsuppressed — each
  /// window applies its own own-mutation logic.
  void forwardTick(String repoPath, RepoWatchEvent event) {
    final payload = {
      'repoPath': repoPath,
      'mode': event.mode.name,
      'atMs': event.at.millisecondsSinceEpoch,
    };
    for (final w in state) {
      if (w.repoPath == repoPath) {
        _hubs[w.id]?.invokeMethod<void>('repoTick', payload).catchError((_) {});
      }
    }
  }

  /// The set of distinct repoPaths currently shown by open windows — the
  /// watchers [windowTickForwardersProvider] must keep alive.
  Set<String> get watchedRepoPaths => {
    for (final w in state)
      if (w.repoPath != null) w.repoPath!,
  };

  Future<Object?> _onControlCall(MethodCall call) async {
    if (call.method == 'windowClosed') {
      final id = (call.arguments as Map?)?['windowId'] as String?;
      if (id != null) _forget(id);
    }
    return null;
  }

  void _onConnectionChanged(ConnectionState? previous, ConnectionState next) {
    if (state.isEmpty) return;
    final disconnected = next.phase == ConnectionPhase.disconnected;
    // Snapshot the ids first — pushing may mutate `state` (history repo retarget).
    for (final w in List<WindowHandle>.of(state)) {
      // A History window retargets to follow the active repo; a repo-bound
      // window keeps its pinned repo across session changes.
      final handle = w.kind == WindowKind.history && next.isConnected
          ? _retarget(w, next.repoPath)
          : w;
      _hubs[w.id]
          ?.invokeMethod<void>('connectionChanged', _snapshotFor(handle, next).encode())
          .catchError((_) {});
      if (disconnected) {
        // The window follows the session — close it. The child also asks Swift
        // to close on seeing a disconnected snapshot; both paths are idempotent.
        close(w.id);
      }
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
        // which repo is active in the main window.
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

  /// Serves one call from window [id]'s child isolate. Identical semantics to
  /// the former single-window bridge, but requestState answers with THIS
  /// window's pinned repo so a detached window shows its own repo, not the
  /// active one.
  Future<Object?> _onHubCall(String id, MethodCall call) async {
    switch (call.method) {
      case 'execute':
        final request = decodeExecuteRequest(
          call.arguments as Map<Object?, Object?>,
        );
        try {
          // Read per call so a backend switch mid-session is honored.
          final result = await ref.read(activeExecutorProvider).execute(
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
        final handle = _handle(id);
        // The window exists and is asking — if the registry raced (native
        // opened it but our optimistic add was rolled back), synthesize a
        // handle from the live connection so it still gets a snapshot.
        final resolved = handle ??
            WindowHandle(
              id: id,
              kind: WindowKind.history,
              repoPath: ref.read(connectionProvider).repoPath,
            );
        return _snapshotFor(resolved, ref.read(connectionProvider)).encode();
      case 'undoRecord':
        final record = UndoRecord.fromJson(
          call.arguments as Map<Object?, Object?>,
        );
        // A null record means version skew — drop it. Mark it as window-
        // originated first so the main window's journal-driven UndoToastOverlay
        // stays silent — the originating window already showed its own toast.
        if (record != null) {
          ref.read(historyOriginUndoProvider.notifier).mark(record);
          ref.read(undoJournalProvider.notifier).push(record);
        }
        return null;
      case 'performUndo':
        // ⌘Z pressed in a secondary window. The journal (and the executor that
        // can safely run the undo script) live here; all user-facing UI for the
        // outcome renders back in that window from the reply, so `force` only
        // ever arrives after a user confirmed there.
        final args = call.arguments as Map<Object?, Object?>;
        final repoPath = args['repoPath'] as String?;
        if (repoPath == null) return {'status': UndoStatus.nothingToUndo.name};
        try {
          final attempt = await ref
              .read(undoControllerProvider)
              .undo(repoPath, force: args['force'] == true);
          final description = attempt.record?.description;
          if (attempt.status == UndoStatus.done) {
            ref.read(outputLogProvider.notifier).logInfo('Undid: $description');
          }
          return {'status': attempt.status.name, 'description': ?description};
        } on GitException catch (e) {
          return {'status': 'error', 'message': '$e'};
        } catch (e) {
          return {'status': 'error', 'message': 'Undo failed: $e'};
        }
      case 'settingsChanged':
        // A window persisted a settings edit; adopt it here (each isolate
        // caches its own SharedPreferences). The echo terminates: reloading
        // re-broadcasts settingsChanged, but a window's send is gated on a
        // value *change*, which a same-value reload isn't.
        await ref.read(appSettingsProvider.notifier).reloadFromDisk();
        return null;
      case 'mutationPerformed':
        final repoPath =
            (call.arguments as Map<Object?, Object?>)['repoPath'] as String?;
        if (repoPath != null) {
          // Same refresh contract as a local mutation call site: mark so the
          // watcher echo is suppressed, bump the edit generation, and refresh
          // what a mutation can change.
          ref.read(ownMutationTrackerProvider).mark(repoPath);
          noteWorktreeEdit(repoPath);
          for (final p in repoMutationFamilies(repoPath)) {
            ref.invalidate(p);
          }
        }
        return null;
    }
    return null;
  }

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

/// Keeps a watcher alive for every repo shown by an open window and forwards its
/// ticks — but only for repos actually on screen somewhere, so closed windows
/// cost nothing. Watched by AppShell alongside the bridge.
final windowTickForwardersProvider = Provider<void>((ref) {
  final bridge = ref.watch(windowManagerBridgeProvider.notifier);
  final repoPaths = ref.watch(
    windowManagerBridgeProvider.select(
      (windows) => {
        for (final w in windows)
          if (w.repoPath != null) w.repoPath!,
      },
    ),
  );
  for (final repoPath in repoPaths) {
    ref.listen(repoWatchProvider(repoPath), (previous, next) {
      final event = next.value;
      if (event == null) return;
      bridge.forwardTick(repoPath, event);
    });
  }
});
