/// The Dart side of every native secondary window — a second Flutter engine
/// (own isolate, own ProviderScope) whose every git command is proxied to the
/// main isolate over that window's per-window hub channel (see
/// [ProxyCommandExecutor]). The Swift `SecondaryWindowController` relays hub
/// traffic verbatim between the two engines and answers a small per-engine
/// allowlist on the bootstrap channel itself (`descriptor`, `ready`,
/// `setWindowTitle`, `closeSelf`, `debugLog`).
///
/// One generic entrypoint (`secondaryWindowMain` in lib/main.dart) boots this
/// for ALL window kinds; the child learns which window it is — its id, kind, and
/// pinned repo — from the [WindowDescriptor] it pulls over the bootstrap channel
/// at startup, then renders accordingly.
///
/// Hard rule: this isolate must never touch window_manager or WindowManipulator
/// — both are single-window plugins owned by the main engine; this window's
/// bounds live in AppKit's `frameAutosaveName`.
library;

import 'dart:async';
import 'dart:ui' show FramePhase;

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/exec_proxy_codec.dart';
import '../../core/exec/proxy_command_executor.dart';
import '../../core/git/git_service.dart';
import '../../core/git/watch_event.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/keymap.dart';
import '../../core/theme/app_theme.dart';
import '../../core/window/window_channels.dart';
import '../../core/window/window_kind.dart';
import '../common/actions.dart';
import '../common/escape_dismissible.dart';
import '../common/undo_toast.dart';
import '../history/history_view.dart';
import '../recovery/recovery_sheet.dart';
import '../repository/repo_status_view.dart';
import 'secondary_window_binding.dart';

/// The per-engine bootstrap/allowlist channel (fixed name; each engine has its
/// own messenger, so there is no collision). Carries the descriptor pull and
/// every native-side per-window op.
const _bootstrap = MethodChannel(windowBootstrapChannel);

/// Master switch for the secondary-window diagnostics that trace to
/// hw-debug.log — per-pointer-down coordinates, per-route breadcrumbs, and the
/// vsync/frame-timing probe. OFF in shipped builds. Re-enable with
/// `--dart-define=WINDOW_DIAGNOSTICS=true` and rebuild. Uncaught-error
/// forwarding (below) is NOT gated by this — that trail is load-bearing for a
/// windowless release engine and only fires on an actual error.
const bool kWindowDiagnostics = bool.fromEnvironment('WINDOW_DIAGNOSTICS');

/// Fire-and-forget native op over the bootstrap channel (`ready`,
/// `setWindowTitle`, `closeSelf`, `debugLog`). Errors are swallowed — a message
/// that can't be delivered mid-teardown has no one left to care about it.
void _native(String method, [Object? arguments]) {
  _bootstrap.invokeMethod<void>(method, arguments).catchError((_) {});
}

/// Entrypoint body — called by `secondaryWindowMain()` in lib/main.dart (the
/// `@pragma('vm:entry-point')` stub must live in the root library, because
/// macOS `FlutterEngine.run(withEntrypoint:)` resolves names there).
///
/// The whole boot runs inside a guarded zone so one window's uncaught Dart error
/// can never cascade — it's logged and swallowed, this window degrades alone.
/// (Native crashes still share the process; true per-window crash isolation
/// would need separate processes, out of scope.)
void runSecondaryWindow() {
  runZonedGuarded(_bootSecondaryWindow, (error, stack) {
    _native('debugLog', 'Zone error: $error\n$stack');
  });
}

Future<void> _bootSecondaryWindow() async {
  SecondaryWindowBinding.ensureInitialized();
  // This engine has no visible console (release build, second engine), so an
  // uncaught error would otherwise vanish without a trace. Ship every error to
  // the native side's hw-debug.log over the always-available bootstrap channel.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    _native('debugLog', 'FlutterError: ${details.exception}\n${details.stack}');
    defaultOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _native('debugLog', 'Uncaught: $error\n$stack');
    // Handled: logged is better than letting the zone kill this window's event
    // processing over one bad async path.
    return true;
  };

  final descriptor = await _fetchDescriptor();
  _installLifecycle(descriptor.windowId);
  final hub = MethodChannel(windowHubChannel(descriptor.windowId));
  void sendHub(String method, [Object? arguments]) {
    hub.invokeMethod<void>(method, arguments).catchError((_) {});
  }

  runApp(
    ProviderScope(
      // Same rationale as the main isolate: git failures are deterministic,
      // surface them instead of hiding them behind Riverpod's default retry.
      retry: (_, _) => null,
      overrides: [
        // THE seam: every provider below GitService runs unchanged; only the
        // transport is swapped for the per-window proxy. The exclusive-lane
        // callback marks our own-mutation tracker (so the forwarded watcher
        // tick doesn't double-refresh us) and tells the main window to refresh.
        activeExecutorProvider.overrideWith(
          (ref) => ProxyCommandExecutor.forWindow(
            descriptor.windowId,
            onMutationCompleted: (repoPath) {
              ref.read(ownMutationTrackerProvider).mark(repoPath);
              sendHub('mutationPerformed', {'repoPath': repoPath});
            },
          ),
        ),
        // Identical construction to the production gitServiceProvider except
        // undo records are forwarded to the main window's journal — the single
        // source of undo truth (this window's ⌘Z executes against it via
        // `performUndo`; a journal split across isolates would drift).
        gitServiceProvider.overrideWith((ref) {
          final (
            commitTimeout,
            networkTimeout,
            committerName,
            committerEmail,
          ) = ref.watch(
            appSettingsProvider.select(
              (s) => (
                s.commitTimeout,
                s.networkTimeout,
                s.committerName,
                s.committerEmail,
              ),
            ),
          );
          return GitService(
            ref.watch(activeExecutorProvider),
            commitTimeout: commitTimeout,
            networkTimeout: networkTimeout,
            committerName: committerName,
            committerEmail: committerEmail,
            onUndoRecord: (record) {
              sendHub('undoRecord', record.toJson());
              // The main window's post-mutation toast is journal-driven; our
              // journal lives over there, so raise the same "⌘Z to undo"
              // affordance directly — the mutation happened in THIS window.
              ref
                  .read(undoToastProvider.notifier)
                  .show(UndoToast(record.description, showUndoHint: true));
            },
          );
        }),
        // Defensive: nothing in the rendered views' graph watches this, but the
        // real implementation would call executeStream through the proxy and
        // throw. Watcher ticks arrive as pushed `repoTick` events instead.
        repoWatchProvider.overrideWith(
          (ref, repoPath) => const Stream<RepoWatchEvent>.empty(),
        ),
      ],
      child: SecondaryWindowApp(descriptor: descriptor, hub: hub),
    ),
  );
}

/// Pulls this window's [WindowDescriptor] from native. The controller installs
/// the bootstrap handler before `engine.run()`, so the first attempt normally
/// succeeds; the bounded retry only covers a pathological startup race. On total
/// failure it degrades to a History descriptor so the window at least renders
/// its waiting state rather than hanging invisibly (the native 1.5s reveal
/// backstop still shows it).
Future<WindowDescriptor> _fetchDescriptor() async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      final reply =
          await _bootstrap.invokeMethod<Map<Object?, Object?>>('descriptor');
      if (reply != null) return WindowDescriptor.decode(reply);
    } on PlatformException {
      // Handler present but errored — retry.
    } on MissingPluginException {
      // Handler not installed yet — retry.
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  _native('debugLog', 'descriptor handshake failed — rendering waiting state');
  return const WindowDescriptor(windowId: '', kind: 'history');
}

/// Listens for native occlusion/minimize pushes and drives the framework's
/// AppLifecycleState from them. Feeding the state through the standard
/// `flutter/lifecycle` pathway (rather than a protected binding method) makes
/// [SchedulerBinding] stop producing frames while the window is hidden — the
/// whole point of pausing an occluded window's engine — and resume cleanly when
/// it reappears (the frame-clock self-heal handles the cold vsync).
void _installLifecycle(String windowId) {
  MethodChannel(windowLifecycleChannel(windowId)).setMethodCallHandler((
    call,
  ) async {
    if (call.method == 'setLifecycleState' && call.arguments is String) {
      ServicesBinding.instance.channelBuffers.push(
        'flutter/lifecycle',
        const StringCodec().encodeMessage('AppLifecycleState.${call.arguments}'),
        (_) {},
      );
    }
    return null;
  });
}

/// The slice of the main window's connection state this window renders from.
/// Fed exclusively by the `requestState` handshake and pushed `connectionChanged`
/// events — the local `connectionProvider` sits inert. The [repoPath] is the
/// window's own (a detached window stays pinned to its repo regardless of what
/// is active in the main window).
class WindowSession {
  final ConnectionPhase phase;
  final ConnectionBackend backend;
  final String? repoPath;
  final String? connectionLabel;

  const WindowSession({
    this.phase = ConnectionPhase.disconnected,
    this.backend = ConnectionBackend.ssh,
    this.repoPath,
    this.connectionLabel,
  });

  bool get isConnected => phase == ConnectionPhase.connected;
}

class WindowSessionNotifier extends Notifier<WindowSession> {
  @override
  WindowSession build() => const WindowSession();

  void apply(ConnectionEventPayload payload) {
    state = WindowSession(
      phase: ConnectionPhase.values.asNameMap()[payload.phase] ??
          ConnectionPhase.disconnected,
      backend: ConnectionBackend.values.asNameMap()[payload.backend] ??
          ConnectionBackend.ssh,
      repoPath: payload.repoPath,
      connectionLabel: payload.connectionLabel,
    );
  }
}

final windowSessionProvider =
    NotifierProvider<WindowSessionNotifier, WindowSession>(
  WindowSessionNotifier.new,
);

/// Diagnostics (gated by [kWindowDiagnostics]): route-level breadcrumbs so
/// hw-debug.log shows whether a tapped control's menu/sheet route actually
/// pushed. Installed only when the flag is on.
class _HubLogNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _native('debugLog', 'route push: ${route.runtimeType}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _native('debugLog', 'route pop: ${route.runtimeType}');
  }
}

class SecondaryWindowApp extends StatelessWidget {
  const SecondaryWindowApp({
    super.key,
    required this.descriptor,
    required this.hub,
  });

  final WindowDescriptor descriptor;
  final MethodChannel hub;

  @override
  Widget build(BuildContext context) {
    final title = descriptor.title ??
        (WindowKind.fromName(descriptor.kind) == WindowKind.history
            ? 'History — Magic Git'
            : 'Magic Git');
    return MacosApp(
      title: title,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      navigatorObservers: kWindowDiagnostics
          ? [_HubLogNavigatorObserver()]
          : const <NavigatorObserver>[],
      home: SecondaryWindowShell(descriptor: descriptor, hub: hub),
    );
  }
}

/// Owns the hub handler and the session lifecycle: installs the handler,
/// announces `ready` (revealing the native window), requests the initial
/// connection snapshot, and translates pushed events into provider
/// invalidations — the same refresh semantics the in-app tabs get from the live
/// watcher and mutation call sites.
class SecondaryWindowShell extends ConsumerStatefulWidget {
  const SecondaryWindowShell({
    super.key,
    required this.descriptor,
    required this.hub,
  });

  final WindowDescriptor descriptor;
  final MethodChannel hub;

  @override
  ConsumerState<SecondaryWindowShell> createState() =>
      _SecondaryWindowShellState();
}

class _SecondaryWindowShellState extends ConsumerState<SecondaryWindowShell>
    with SingleTickerProviderStateMixin {
  /// Same suppression window as the repo panel's watcher listener: a tick
  /// arriving within this of our own mutation is that mutation's echo.
  static const _ownMutationSuppressWindow = Duration(seconds: 3);

  MethodChannel get _hub => widget.hub;
  WindowKind get _kind => WindowKind.fromName(widget.descriptor.kind);

  /// The Recovery sheet's live route while it's open — same provider-driven
  /// route pattern as AppShell's `_recoveryRoute`, so the filter-bar button and
  /// Esc/X can never disagree about visibility.
  ModalRoute<void>? _recoveryRoute;

  /// Debounces the settings→main sync for edits ORIGINATING in this window (the
  /// zoom gestures and the diff word-wrap toggle). Zoom fires dozens of
  /// [AppSettingsNotifier.setHistoryZoom] calls (each persisting to disk), so
  /// the main isolate should reload once, after the burst.
  Timer? _settingsSyncDebounce;

  // Diagnostics (gated by kWindowDiagnostics): a 300ms animation measured after
  // 2s — if `value` isn't 1.0/completed, this engine's vsync never drives
  // tickers, which is exactly the "pushed routes stay at their opacity-0
  // entrance frame" failure. The frame-timings samples separate "no frames at
  // all" from "frames tick but animation clocks are frozen".
  AnimationController? _vsyncProbe;
  Timer? _vsyncProbeTimer;
  TimingsCallback? _timingsProbe;
  int _timingsSeen = 0;

  @override
  void initState() {
    super.initState();
    _hub.setMethodCallHandler(_onHubCall);
    if (kWindowDiagnostics) {
      _vsyncProbe = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      )..forward();
      _timingsProbe = (List<FrameTiming> timings) {
        if (_timingsSeen >= 2) return;
        _timingsSeen++;
        final t = timings.first;
        _native(
          'debugLog',
          'frame timings[$_timingsSeen]: ${timings.length} frames, '
          'vsyncStart=${t.timestampInMicroseconds(FramePhase.vsyncStart)}µs '
          'rasterFinish=${t.timestampInMicroseconds(FramePhase.rasterFinish)}µs',
        );
      };
      SchedulerBinding.instance.addTimingsCallback(_timingsProbe!);
      _vsyncProbeTimer = Timer(const Duration(seconds: 2), () {
        final probe = _vsyncProbe;
        if (probe == null) return;
        _native(
          'debugLog',
          'vsync probe: ${probe.status.name} value=${probe.value} '
          'mouseConnected=${RendererBinding.instance.mouseTracker.mouseIsConnected}',
        );
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Reveal the native window only once real content exists (it opens at
      // alpha 0 — same flash-free dance as the main window).
      _native('ready');
      // Pull the initial snapshot rather than waiting for a push — pushes sent
      // before this handler existed were dropped by design.
      try {
        final reply =
            await _hub.invokeMethod<Map<Object?, Object?>>('requestState');
        if (reply != null && mounted) {
          _applySession(ConnectionEventPayload.decode(reply));
        }
      } on PlatformException {
        // Bridge not up (shouldn't happen — it opened this window); the next
        // connectionChanged push recovers.
      }
    });
  }

  @override
  void dispose() {
    _settingsSyncDebounce?.cancel();
    _vsyncProbeTimer?.cancel();
    _vsyncProbe?.dispose();
    _vsyncProbe = null;
    final timings = _timingsProbe;
    if (timings != null) {
      SchedulerBinding.instance.removeTimingsCallback(timings);
    }
    _hub.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _onHubCall(MethodCall call) async {
    // Wire data — never hard-cast; a malformed push is dropped, not thrown.
    final args = call.arguments;
    switch (call.method) {
      case 'connectionChanged':
        if (args is Map<Object?, Object?>) {
          _applySession(ConnectionEventPayload.decode(args));
        }
      case 'repoTick':
        if (args is Map<Object?, Object?>) _onRepoTick(args);
      case 'invalidateAll':
        for (final family in repoScopedFetchFamilies) {
          ref.invalidate(family);
        }
      case 'settingsChanged':
        // Settings are SharedPreferences-backed and each isolate caches its own
        // copy — reload from disk so mid-session changes made elsewhere
        // (committer identity, timeouts) apply to the next command here.
        await ref.read(appSettingsProvider.notifier).reloadFromDisk();
    }
    return null;
  }

  void _applySession(ConnectionEventPayload payload) {
    final previous = ref.read(windowSessionProvider);
    ref.read(windowSessionProvider.notifier).apply(payload);
    final session = ref.read(windowSessionProvider);

    if (session.phase == ConnectionPhase.disconnected) {
      // The window follows the session — nothing meaningful to show once the
      // session is gone. Swift closes us and notifies the bridge.
      _native('closeSelf');
      return;
    }
    if (session.repoPath != previous.repoPath && session.repoPath != null) {
      // A different repo (or the first one): drop everything fetched for the
      // old key. The private LRUs in app_providers keep their (hash-immutable)
      // entries — memory-only; the generation bump below covers the
      // worktree-sensitive tier.
      for (final family in repoScopedFetchFamilies) {
        ref.invalidate(family);
      }
      noteWorktreeEdit(session.repoPath!);
      // Fresh repo, fresh suppression state — mirrors ConnectionController.
      ref.read(ownMutationTrackerProvider).clear();
      // An open Recovery sheet targets the old repo — close it rather than show
      // stale refs under a new title.
      ref.read(recoveryVisibleProvider.notifier).setVisible(false);
    }
    final repoName = session.repoPath?.split('/').last;
    final prefix = _kind == WindowKind.history ? 'History' : 'Repo';
    _native(
      'setWindowTitle',
      repoName == null
          ? prefix
          : '$prefix — $repoName'
              '${session.connectionLabel == null ? '' : ' (${session.connectionLabel})'}',
    );
  }

  /// ⌘Z (and the toast's click target): the journal lives in the main isolate,
  /// so the actual undo runs there via `performUndo`; every piece of UI it needs
  /// (dirty-overwrite confirm, stale/error dialogs, the "Undid:" toast) renders
  /// here — the window the user is looking at.
  Future<void> _undoGitOperation() async {
    // In-field ⌘Z must stay text undo — same backstop as AppShell.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorStateOfType<EditableTextState>() != null)) {
      return;
    }
    final repoPath = ref.read(windowSessionProvider).repoPath;
    if (repoPath == null) return;
    await _performUndo(repoPath, force: false);
  }

  Future<void> _performUndo(String repoPath, {required bool force}) async {
    Map<Object?, Object?>? reply;
    try {
      reply = await _hub.invokeMethod<Map<Object?, Object?>>('performUndo', {
        'repoPath': repoPath,
        'force': force,
      });
    } on PlatformException catch (e) {
      // RELAY_DOWN = the window is on its way out; anything else is a real
      // main-isolate failure the user must see (the bridge replies errors as
      // data, so this path is unexpected — but never silent).
      if (e.code == 'RELAY_DOWN' || !mounted) return;
      await showErrorDialog(context, e.message ?? 'Undo failed.');
      return;
    }
    if (reply == null || !mounted) return;
    final status = reply['status'] as String?;
    final description = reply['description'] as String? ?? 'operation';
    switch (status) {
      case 'done':
        ref
            .read(undoToastProvider.notifier)
            .show(UndoToast('Undid: $description'));
        _refreshAfterUndo(repoPath);
      case 'dirty':
        final overwrite = await confirmAction(
          context,
          title: 'Files Changed Since',
          message: 'Undoing "$description" would overwrite files that changed '
              'after the operation ran. Overwrite them?',
          confirmLabel: 'Overwrite',
          destructive: true,
        );
        if (overwrite && mounted) {
          await _performUndo(repoPath, force: true);
        }
      case 'stale':
        await showErrorDialog(
          context,
          'The repository has changed since "$description" — this undo is no '
          'longer safe and has been discarded.',
        );
      case 'error':
        await showErrorDialog(
          context,
          reply['message'] as String? ?? 'Undo failed.',
        );
      default:
        // nothingToUndo / blockedByPendingOp — silent, matching AppShell.
        break;
    }
  }

  /// The main isolate already refreshed its own providers as part of the undo;
  /// mirror that here (the forwarded watcher tick would catch up eventually, but
  /// immediate is what the user expects mid-gaze).
  void _refreshAfterUndo(String repoPath) {
    ref.read(ownMutationTrackerProvider).mark(repoPath);
    noteWorktreeEdit(repoPath);
    _invalidateRepoFamilies(repoPath);
  }

  /// The one invalidation set every refresh path here shares — tick, undo, and
  /// Recovery restores all agree, so an open Recovery sheet can never show a
  /// pre-mutation reflog. Invalidating unwatched families is free.
  void _invalidateRepoFamilies(String repoPath) {
    for (final p in repoMutationFamilies(repoPath)) {
      ref.invalidate(p);
    }
  }

  void _onRepoTick(Map<Object?, Object?> args) {
    final repoPath = args['repoPath'] as String?;
    if (repoPath == null ||
        repoPath != ref.read(windowSessionProvider).repoPath) {
      return;
    }
    final at = DateTime.fromMillisecondsSinceEpoch(
      args['atMs'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    );
    // Our own proxied mutation already refreshed both windows — skip its echo.
    if (ref
        .read(ownMutationTrackerProvider)
        .isRecent(repoPath, at, _ownMutationSuppressWindow)) {
      return;
    }
    if (args['mode'] == WatchMode.eventDriven.name) {
      noteWorktreeEdit(repoPath);
    }
    // Unlike the in-app tab (whose panels each refresh what they watch), the
    // tick is this window's ONLY freshness signal for main-window mutations.
    _invalidateRepoFamilies(repoPath);
  }

  @override
  Widget build(BuildContext context) {
    // The Recovery sheet opens locally in this window (full parity with the
    // in-app tab) — the reflog/snapshot reads and restore actions all flow
    // through the same proxied executor as everything else here.
    ref.listen(recoveryVisibleProvider, (_, visible) {
      final repoPath = ref.read(windowSessionProvider).repoPath;
      if (visible && _recoveryRoute == null && repoPath != null) {
        showMacosSheet<void>(
          context: context,
          builder: (sheetContext) {
            _recoveryRoute = ModalRoute.of(sheetContext);
            return EscapeDismissible(child: RecoverySheet(repoPath: repoPath));
          },
        ).whenComplete(() {
          _recoveryRoute = null;
          if (mounted) {
            ref.read(recoveryVisibleProvider.notifier).setVisible(false);
          }
        });
      } else if (!visible && _recoveryRoute != null) {
        final route = _recoveryRoute!;
        _recoveryRoute = null;
        if (route.isCurrent) {
          Navigator.of(context, rootNavigator: true).pop();
        } else if (route.isActive) {
          Navigator.of(context, rootNavigator: true).removeRoute(route);
        }
      }
    });
    // Settings changed HERE (⌘=/⌘−/pinch zoom, or the diff word-wrap toggle,
    // all persisted from this isolate) must tell the main isolate to reload its
    // own SharedPreferences cache. Gated on a value *change* via a record select
    // — records compare by value, so the main window's settingsChanged push
    // (whose reload re-lands the same values here) can't ping-pong back.
    ref.listen(
      appSettingsProvider.select((s) => (s.historyZoom, s.historyDiffWrap)),
      (_, _) {
        _settingsSyncDebounce?.cancel();
        _settingsSyncDebounce = Timer(const Duration(milliseconds: 600), () {
          _hub.invokeMethod<void>('settingsChanged').catchError((_) {});
        });
      },
    );
    final session = ref.watch(windowSessionProvider);
    final typography = MacosTheme.of(context).typography;
    // During a drop (`lost`) keep the content visible under a banner —
    // frozen-but-readable beats a blank window while auto-reconnect runs;
    // proxied commands fail fast with the dialogs users already know.
    final showBody = session.repoPath != null &&
        (session.isConnected || session.phase == ConnectionPhase.lost);
    // Only the keymap actions that mean something in this window; the rest
    // (panels, palette, refresh) belong to the main shell.
    final shortcuts = resolveShortcuts(ref.watch(keymapProvider), {
      'global.undo': showBody ? _undoGitOperation : null,
    });
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        // Diagnostics (gated by kWindowDiagnostics): proves whether clicks reach
        // this Flutter view at all, and where. Null handler when off — the
        // Listener is then an inert passthrough.
        child: Listener(
          onPointerDown: kWindowDiagnostics
              ? (event) => _native(
                    'debugLog',
                    'pointerDown ${event.position.dx.round()},'
                        '${event.position.dy.round()}',
                  )
              : null,
          child: MacosWindow(
            child: ContentArea(
              builder: (context, _) => Stack(
                children: [
                  if (!showBody)
                    Center(
                      child: Text(
                        'Waiting for session…',
                        style: typography.body.copyWith(
                          color: MacosColors.systemGrayColor,
                        ),
                      ),
                    )
                  else
                    Column(
                      children: [
                        if (session.phase == ConnectionPhase.lost)
                          Container(
                            width: double.infinity,
                            color: MacosColors.systemOrangeColor.withValues(
                              alpha: 0.18,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            child: Text(
                              'Connection lost — reconnecting… actions will '
                              'fail until the session returns.',
                              style: typography.caption1.copyWith(
                                color: MacosColors.systemOrangeColor,
                              ),
                            ),
                          ),
                        Expanded(child: _body(session.repoPath!)),
                      ],
                    ),
                  // Same top layer as AppShell's Stack: "<op> — ⌘Z to undo"
                  // after this window's own mutations, "Undid: …" after ⌘Z.
                  UndoToastOverlay(onUndo: _undoGitOperation),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The window's content, chosen by kind: History renders the History view; a
  /// detached repo window renders the full status view for its pinned repo.
  Widget _body(String repoPath) => switch (_kind) {
    WindowKind.history => HistoryView(repoPath: repoPath, isActive: true),
    WindowKind.detachedRepo =>
      RepoStatusView(repoPath: repoPath, isActive: true),
  };
}
