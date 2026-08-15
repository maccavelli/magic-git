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
import '../../core/settings/pane_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/git_porcelain_parser.dart' show GitStatus;
import '../../core/window/window_channels.dart';
import '../../core/window/window_kind.dart';
import '../common/actions.dart';
import '../common/escape_dismissible.dart';
import '../common/undo_toast.dart';
import '../history/history_view.dart';
import '../recovery/recovery_sheet.dart';
import '../repository/repo_status_view.dart';
import '../viewer/remote_edit_service.dart';
import '../viewer/viewer_host.dart';
import 'secondary_window_binding.dart';
import 'secondary_window_scope.dart';

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

/// The value-comparable signature of every setting this window can EDIT
/// locally — the record its settings-sync listener selects on. A setting
/// missing from here is a setting whose pop-out edits the main window never
/// hears about, so: zoom and word-wrap (the History gestures/toggle), plus
/// every pane width (the divider drags), folded to a string because a Map
/// field can't ride a record select (two rebuilt maps with equal contents are
/// `!=`, which would re-arm the exact ping-pong the record exists to stop).
/// All pane ids are signed — not just the panes this window renders — so a
/// future pane can't be forgotten here.
(double, bool, bool, String) secondarySettingsSyncSignature(AppSettings s) => (
  s.historyZoom,
  s.historyDiffWrap,
  s.historyAllBranches,
  PaneId.values.map((id) => '${id.name}:${s.paneWidth(id)}').join(','),
);

/// Forwards every provider failure to the native side's hw-debug.log.
///
/// This engine has no visible console, and a failed FutureProvider is
/// invisible wherever the UI deliberately reads it as best-effort (History's
/// ref decorations render a bare graph on `.value ?? const []`) — a fetch
/// that dies here otherwise leaves no trace anywhere. Same rationale as the
/// FlutterError/uncaught-zone forwarding in [_bootSecondaryWindow]: only
/// fires on an actual error, so it is not gated by [kWindowDiagnostics].
final class _ProviderFailureLogObserver extends ProviderObserver {
  const _ProviderFailureLogObserver();

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    final provider = context.provider;
    _native(
      'debugLog',
      'provider failed: ${provider.name ?? provider.runtimeType}'
          '(${provider.argument ?? ''}): $error\n$stackTrace',
    );
  }
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
      observers: const [_ProviderFailureLogObserver()],
      overrides: [
        // THE seam: every provider below GitService runs unchanged; only the
        // transport is swapped for the per-window proxy. The exclusive-lane
        // callback marks our own-mutation tracker (so the forwarded watcher
        // tick doesn't double-refresh us) and tells the main window to refresh.
        activeExecutorProvider.overrideWith((ref) {
          final executor = ProxyCommandExecutor.forWindow(
            descriptor.windowId,
            onMutationCompleted: (repoPath) {
              ref.read(ownMutationTrackerProvider).mark(repoPath);
              sendHub('mutationPerformed', {'repoPath': repoPath});
            },
          );
          // Fails anything still waiting on the main window and drops the
          // liveness probe, rather than leaving a timer pinging a channel this
          // window no longer listens to.
          ref.onDispose(executor.dispose);
          return executor;
        }),
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
        // INVARIANT: the pop-out receives file-system change notifications via
        // pushed `repoTick` events from the main window (see _onHubCall), NOT
        // from its own watcher. The real repoWatchProvider depends on
        // connectionProvider → backend → LocalWatchService/RemoteWatchService,
        // none of which exist in this isolate. Any view code added to the
        // pop-out that accidentally watches repoWatchProvider will see an empty
        // stream (harmless) rather than a cascading provider-resolution crash.
        // If you need FS-change reactivity here, use the hub's repoTick push.
        repoWatchProvider.overrideWith(
          (ref, repoPath) => const Stream<RepoWatchEvent>.empty(),
        ),
        // Mirror the wire's phase/backend into connectionProvider: gates like
        // Reveal-in-Finder / Open-file / viewer "Open in Default App" read
        // `connectionProvider.isLocal`, and the inert default read every
        // detached local repo as a disconnected SSH one (0009 M25).
        connectionProvider.overrideWith(WindowConnection.new),
      ],
      child: SecondaryWindowApp(descriptor: descriptor, hub: hub),
    ),
  );
}

/// The secondary isolate's [connectionProvider]: a read-only projection of
/// [windowSessionProvider] (the `requestState` handshake + pushed
/// `connectionChanged` events). sessionEpoch stays 0 — epoch-keyed machinery
/// (supplements, navigation history) belongs to the main window.
class WindowConnection extends ConnectionController {
  @override
  ConnectionState build() {
    final session = ref.watch(windowSessionProvider);
    return ConnectionState(
      phase: session.phase,
      backend: session.backend,
      repoPath: session.repoPath,
      connectionLabel: session.connectionLabel,
    );
  }
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
      final reply = await _bootstrap.invokeMethod<Map<Object?, Object?>>(
        'descriptor',
      );
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
        const StringCodec().encodeMessage(
          'AppLifecycleState.${call.arguments}',
        ),
        (_) {},
      );
    }
    return null;
  });
}

/// The slice of the main window's connection state this window renders from.
/// Fed exclusively by the `requestState` handshake and pushed `connectionChanged`
/// events — the local `connectionProvider` is overridden to project THIS
/// (see `_WindowConnection`), so backend-gated affordances (Reveal in
/// Finder, Open file) see the real backend. The [repoPath] is the window's
/// own (a detached window stays pinned to its repo regardless of what is
/// active in the main window).
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
      phase:
          ConnectionPhase.values.asNameMap()[payload.phase] ??
          ConnectionPhase.disconnected,
      backend:
          ConnectionBackend.values.asNameMap()[payload.backend] ??
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
    final title =
        descriptor.title ??
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
      // The scope lives here (not in the runApp bootstrap) so every mount
      // of this app — production and widget tests alike — carries it.
      home: SecondaryWindowScope(
        child: SecondaryWindowShell(descriptor: descriptor, hub: hub),
      ),
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

  /// Polling-mode head-move probe for a HISTORY window. In polling mode a
  /// tick carries no git-state signal, and this shell used to drop it
  /// entirely for the History kind — an external (or main-window) commit
  /// never reached the pop-out until the mode recovered. Mirror the main
  /// window's answer (RepoStatusView's detector): each polling tick refetches
  /// the cheap status snapshot, and a HEAD move between two landed statuses —
  /// the one signal polling mode gets — refreshes the mutation families.
  /// Created lazily on the first polling tick so the (fswatch-healthy)
  /// event-driven case never pays the extra status subscription; torn down
  /// when event-driven ticks resume, on a repo switch, and on dispose.
  /// A detached-repo window needs none of this: its RepoStatusView already
  /// watches status and runs the same detector itself.
  ProviderSubscription<AsyncValue<GitStatus>>? _pollHeadProbe;
  String? _pollHeadProbeRepo;

  void _ensurePollHeadProbe(String repoPath) {
    if (_pollHeadProbe != null && _pollHeadProbeRepo == repoPath) return;
    _pollHeadProbe?.close();
    _pollHeadProbeRepo = repoPath;
    _pollHeadProbe = ref.listenManual(statusProvider(repoPath), (
      previous,
      next,
    ) {
      final prev = previous?.value;
      final curr = next.value;
      // Riverpod emits loading-with-previous-value before data lands — only
      // compare two LANDED statuses.
      if (next.isLoading || prev == null || curr == null) return;
      if (prev.branch.oid == curr.branch.oid &&
          prev.branch.head == curr.branch.head) {
        return;
      }
      // A move our own proxied mutation caused already refreshed everything
      // (onMutationCompleted → mark + refresh); this catches everyone else's.
      if (ref
          .read(ownMutationTrackerProvider)
          .isRecent(repoPath, DateTime.now(), _ownMutationSuppressWindow)) {
        return;
      }
      _invalidateRepoFamilies(repoPath);
    });
  }

  void _dropPollHeadProbe() {
    _pollHeadProbe?.close();
    _pollHeadProbe = null;
    _pollHeadProbeRepo = null;
  }

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
        final reply = await _hub.invokeMethod<Map<Object?, Object?>>(
          'requestState',
        );
        if (reply != null && mounted) {
          _applySession(ConnectionEventPayload.decode(reply));
        }
      } on PlatformException catch (e) {
        // RELAY_DOWN = the pinned tab was already gone by the time we asked, so
        // no connectionChanged push will ever arrive — close instead of hanging
        // forever on "Waiting for session…". Any other platform error is a
        // transient bridge hiccup the next push recovers from.
        if (e.code == 'RELAY_DOWN') _native('closeSelf');
      }
    });
  }

  @override
  void dispose() {
    _dropPollHeadProbe();
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
      // The probe is keyed to the old repo's status — the next polling tick
      // (if the new repo's watcher is also degraded) re-arms it.
      _dropPollHeadProbe();
      // A different repo (or the first one): drop everything fetched for the
      // old key. The private LRUs in app_providers keep their (hash-immutable)
      // entries — memory-only; the generation bump below covers the
      // worktree-sensitive tier.
      for (final family in repoScopedFetchFamilies) {
        ref.invalidate(family);
      }
      // Mirror the main window's ConnectionController._invalidateRepoState:
      // clearing the hash-keyed diff LRUs alongside the invalidation keeps their
      // KeepAliveLink bookkeeping from pinning links to the just-disposed
      // providers — a stale link there breaks delivery of a later fresh fetch to
      // the diff pane (the pop-out "diff doesn't load after switching" bug).
      clearHashKeyedRepoCaches();
      ref.read(worktreeEditsProvider.notifier).noteRepo(session.repoPath!);
      // Fresh repo, fresh suppression state — mirrors ConnectionController.
      ref.read(ownMutationTrackerProvider).clear();
      // An open Recovery sheet targets the old repo — close it rather than show
      // stale refs under a new title.
      ref.read(recoveryVisibleProvider.notifier).setVisible(false);
    }
    final repoName = session.repoPath?.split('/').last;
    // Detached windows are status-only (not a full workspace shell) — M12.
    final prefix = _kind == WindowKind.history ? 'History' : 'Status';
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
            .show(
              UndoToast(
                'Undid: $description',
                showRedoHint: reply['canRedo'] == true,
              ),
            );
        _refreshAfterUndo(repoPath);
      case 'dirty':
        final overwrite = await confirmAction(
          context,
          title: 'Files Changed Since',
          message:
              'Undoing "$description" would overwrite files that changed '
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
      case 'nothingToUndo':
        ref
            .read(undoToastProvider.notifier)
            .show(const UndoToast('Nothing to undo'));
      default:
        // blockedByPendingOp stays silent — the pending-op banner already
        // explains abort/continue.
        break;
    }
  }

  Future<void> _redoGitOperation() async {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorStateOfType<EditableTextState>() != null)) {
      return;
    }
    final repoPath = ref.read(windowSessionProvider).repoPath;
    if (repoPath == null) return;
    Map<Object?, Object?>? reply;
    try {
      reply = await _hub.invokeMethod<Map<Object?, Object?>>('performRedo', {
        'repoPath': repoPath,
      });
    } on PlatformException catch (e) {
      if (e.code == 'RELAY_DOWN' || !mounted) return;
      await showErrorDialog(context, e.message ?? 'Redo failed.');
      return;
    }
    if (reply == null || !mounted) return;
    final status = reply['status'] as String?;
    final description = reply['description'] as String? ?? 'operation';
    switch (status) {
      case 'done':
        ref
            .read(undoToastProvider.notifier)
            .show(UndoToast('Redid: $description', showUndoHint: true));
        _refreshAfterUndo(repoPath);
      case 'stale':
        await showErrorDialog(
          context,
          'The tag changed after "$description" was undone — this redo is no '
          'longer safe and has been discarded.',
        );
      case 'error':
        await showErrorDialog(
          context,
          reply['message'] as String? ?? 'Redo failed.',
        );
      default:
        break;
    }
  }

  /// The main isolate already refreshed its own providers as part of the undo;
  /// mirror that here (the forwarded watcher tick would catch up eventually, but
  /// immediate is what the user expects mid-gaze).
  void _refreshAfterUndo(String repoPath) {
    ref.read(ownMutationTrackerProvider).mark(repoPath);
    ref.read(worktreeEditsProvider.notifier).noteRepo(repoPath);
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
    final modeName = args['mode'] as String? ?? '';
    final mode = WatchMode.values.asNameMap()[modeName] ?? WatchMode.stopped;
    // The main window forwards which paths moved; an empty list means it
    // couldn't say, and every path must be assumed edited.
    final paths = (args['paths'] as List?)?.cast<String>() ?? const <String>[];
    final tick = RepoWatchEvent(at: at, mode: mode, paths: paths.toSet());
    if (mode == WatchMode.eventDriven) {
      final edits = ref.read(worktreeEditsProvider.notifier);
      if (tick.isScoped && !tick.touchesGitState) {
        edits.noteFiles(repoPath, tick.paths);
      } else {
        edits.noteRepo(repoPath);
      }
    }
    // Mirror RepoStatusView's tick policy — NOT "invalidate everything on
    // every heartbeat". The history pop-out used to re-run log + for-each-ref
    // on pure working-tree edits (and polling ticks), racing the proxied
    // snapshot and leaving `refsProvider` in AsyncLoading/error with
    // `value == null`, so branch/tag chips never stayed on screen.
    //
    // Full shared-state refresh only when git's own state may have moved
    // (commit/checkout/fetch/…) or the tick is unscoped. Working-tree-only
    // edits matter for a detached *repo* window (status), not for History.
    if (mode == WatchMode.eventDriven) {
      // Event-driven ticks carry the git-state signal themselves — the
      // polling head-move probe (if one was armed during a polling spell) is
      // redundant cost now.
      _dropPollHeadProbe();
      if (tick.touchesGitState || !tick.isScoped) {
        _invalidateRepoFamilies(repoPath);
        return;
      }
    }
    if (_kind == WindowKind.detachedRepo) {
      ref.invalidate(statusProvider(repoPath));
    } else if (_kind == WindowKind.history && mode == WatchMode.polling) {
      // Polling mode's only external-commit signal is a HEAD move between two
      // landed statuses — arm the probe and land one (see [_pollHeadProbe]).
      _ensurePollHeadProbe(repoPath);
      ref.invalidate(statusProvider(repoPath));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Remote-edit notices (H4) — same UX as the main shell.
    ref.listen(remoteEditNoticeProvider, (previous, next) {
      if (next == null || next == previous) return;
      final notice = next;
      ref.read(remoteEditNoticeProvider.notifier).clear();
      unawaited(() async {
        if (!mounted) return;
        if (notice.isConflict && notice.conflictSessionKey != null) {
          final overwrite = await confirmAction(
            context,
            title: notice.title,
            message:
                '${notice.message}\n\nOverwrite the remote file with your '
                'local editor buffer?',
            confirmLabel: 'Overwrite Remote',
            destructive: true,
          );
          if (overwrite && mounted) {
            await ref
                .read(remoteEditServiceProvider.notifier)
                .forceUploadAfterConflict(notice.conflictSessionKey!);
          } else if (mounted) {
            // Declined — remember the content so the watcher's next tick of
            // the same bytes doesn't re-open this dialog (0009 M24).
            ref
                .read(remoteEditServiceProvider.notifier)
                .declineConflict(notice.conflictSessionKey!);
          }
        } else {
          await showErrorDialog(context, notice.message);
        }
      }());
    });
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
    // Settings changed HERE (⌘=/⌘−/pinch zoom, the diff word-wrap toggle, a
    // pane-divider drag — anything persisted from this isolate) must tell the
    // main isolate to reload its own SharedPreferences cache. Gated on a value
    // *change* via a record select — records compare by value, so the main
    // window's settingsChanged push (whose reload re-lands the same values
    // here) can't ping-pong back. The record is built by
    // [secondarySettingsSyncSignature]; new locally-editable settings go THERE.
    ref.listen(appSettingsProvider.select(secondarySettingsSyncSignature), (
      _,
      _,
    ) {
      _settingsSyncDebounce?.cancel();
      _settingsSyncDebounce = Timer(const Duration(milliseconds: 600), () {
        _hub.invokeMethod<void>('settingsChanged').catchError((_) {});
      });
    });
    final session = ref.watch(windowSessionProvider);
    final typography = MacosTheme.of(context).typography;
    // During a drop (`lost`) keep the content visible under a banner —
    // frozen-but-readable beats a blank window while auto-reconnect runs;
    // proxied commands fail fast with the dialogs users already know.
    final showBody =
        session.repoPath != null &&
        (session.isConnected || session.phase == ConnectionPhase.lost);
    // Only the keymap actions that mean something in this window; the rest
    // (panels, palette) belong to the main shell. ⌘R invalidates repo families
    // (M12) the same way the main shell's refresh does for open pop-outs.
    final shortcuts = resolveShortcuts(ref.watch(keymapProvider), {
      'global.undo': showBody ? _undoGitOperation : null,
      'global.redo': showBody ? _redoGitOperation : null,
      'global.refresh': showBody && session.repoPath != null
          ? () {
              final repo = session.repoPath!;
              for (final family in repoScopedFetchFamilies) {
                ref.invalidate(family);
              }
              // Also ask main to refresh shared state for this repo.
              _hub
                  .invokeMethod<void>('invalidateAll', {'repoPath': repo})
                  .catchError((_) {});
            }
          : null,
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
                        Expanded(
                          // The same float layer AppShell stacks over its
                          // panels: without it, "View file" wrote
                          // openFileViewersProvider (per-isolate) and
                          // nothing in this window rendered it (0009 H14).
                          child: Stack(
                            children: [
                              _body(session.repoPath!),
                              const Positioned.fill(child: ViewerHost()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  // Same top layer as AppShell's Stack: "<op> — ⌘Z to undo"
                  // after this window's own mutations, "Undid: …" after ⌘Z.
                  UndoToastOverlay(
                    onUndo: _undoGitOperation,
                    onRedo: _redoGitOperation,
                  ),
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
  ///
  /// Keyed by [repoPath] so that when a History pop-out FOLLOWS the active tab
  /// to a different repo, the view fully remounts (fresh State — selection,
  /// commit graph, diff panes all reset) rather than mutating in place. A
  /// retarget then behaves exactly like a fresh open, which is the known-good
  /// path; an in-place `didUpdateWidget` update otherwise risks carrying stale
  /// per-repo view state (e.g. a diff pane still bound to the old repo) across
  /// the switch.
  Widget _body(String repoPath) => switch (_kind) {
    WindowKind.history => HistoryView(
      key: ValueKey(repoPath),
      repoPath: repoPath,
      isActive: true,
    ),
    WindowKind.detachedRepo => RepoStatusView(
      key: ValueKey(repoPath),
      repoPath: repoPath,
      isActive: true,
    ),
  };
}
