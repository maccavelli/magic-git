/// The History window's Dart side — a second Flutter engine (own isolate, own
/// ProviderScope) whose every git command is proxied to the main isolate over
/// `magicgit/history/hub` (see `ProxyCommandExecutor`). The Swift
/// `HistoryWindowController` relays hub traffic between the two engines and
/// handles a small native allowlist itself (`ready`, `setWindowTitle`,
/// `closeSelf`).
///
/// Hard rule: this isolate must never touch window_manager or
/// WindowManipulator — both are single-window plugins owned by the main
/// engine; this window's bounds live in AppKit's `frameAutosaveName`.
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

import '../../../core/exec/exec_proxy_codec.dart';
import '../../../core/exec/proxy_command_executor.dart';
import '../../../core/git/git_service.dart';
import '../../../core/git/watch_event.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/keymap.dart';
import '../../../core/theme/app_theme.dart';
import '../../common/actions.dart';
import '../../common/escape_dismissible.dart';
import '../../common/undo_toast.dart';
import '../../recovery/recovery_sheet.dart';
import '../history_view.dart';

const _hub = MethodChannel('magicgit/history/hub');

/// Master switch for the History-window diagnostics that trace to
/// hw-debug.log — the per-pointer-down coordinates, the per-route breadcrumbs,
/// and the vsync/frame-timing probe. OFF in shipped builds, so they neither
/// record user activity to disk nor grow the log. The instrumentation is kept
/// (not deleted) because the dead-controls / tooltip investigation it serves
/// isn't formally closed: re-enable it with
/// `--dart-define=HISTORY_WINDOW_DIAGNOSTICS=true` and rebuild. Uncaught-error
/// forwarding (below) is NOT gated by this — that trail is load-bearing for a
/// windowless release engine and only fires on an actual error.
const bool kHistoryWindowDiagnostics = bool.fromEnvironment(
  'HISTORY_WINDOW_DIAGNOSTICS',
);

/// Fire-and-forget sender for hub events. Errors (relay torn down mid-close)
/// are deliberately swallowed — an event that can't be delivered has no one
/// left to care about it.
void _sendHub(String method, [Object? arguments]) {
  _hub.invokeMethod<void>(method, arguments).catchError((_) {});
}

/// [WidgetsFlutterBinding] with a self-healing frame clock.
///
/// The macOS embedder's vsync waiter is armed when the engine runs. A custom
/// entrypoint forces run() BEFORE the view can join a window (view load
/// auto-launches `main` otherwise), so this second engine's waiter falls
/// back to a viewless path whose frame timestamps never advance — probe
/// evidence: frames render (100-frame batches) but `vsyncStart=0µs` on every
/// frame and an AnimationController pinned at 0.0 forever. Frozen animation
/// clocks leave every pushed route (menus, sheets, dialogs) stuck at its
/// entrance transition's opacity-0 frame: an invisible modal barrier.
///
/// Fix at the exact seam the timestamps enter Dart: when the engine's clock
/// is not advancing, substitute a monotonic wall clock. Healthy timestamps
/// pass through untouched, so this degrades to a no-op if a future Flutter
/// fixes the embedder (re-check via the "vsync probe" line in hw-debug.log
/// on upgrades).
class HistoryWindowBinding extends WidgetsFlutterBinding {
  // Canonical custom-binding pattern: `WidgetsBinding.instance` THROWS on an
  // uninitialized isolate, so existence is tracked with our own field set in
  // initInstances, never probed through the framework getter.
  static HistoryWindowBinding? _instance;

  static HistoryWindowBinding ensureInitialized() {
    if (_instance == null) HistoryWindowBinding();
    return _instance!;
  }

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastPassed = Duration.zero;

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    // null = warm-up frame; the framework substitutes its own stopwatch.
    if (rawTimeStamp == null) return super.handleBeginFrame(null);
    var timeStamp = rawTimeStamp;
    if (timeStamp <= _lastPassed) {
      // Engine clock frozen (or rewound): synthesize forward motion.
      timeStamp = _clock.elapsed;
      if (timeStamp <= _lastPassed) {
        timeStamp = _lastPassed + const Duration(microseconds: 1);
      }
    }
    _lastPassed = timeStamp;
    super.handleBeginFrame(timeStamp);
  }
}

/// Entrypoint body — called by `historyWindowMain()` in `lib/main.dart`
/// (the `@pragma('vm:entry-point')` stub must live in the root library,
/// because macOS `FlutterEngine.run(withEntrypoint:)` resolves names there).
void runHistoryWindow() {
  HistoryWindowBinding.ensureInitialized();
  // This engine has no visible console (release build, second engine), so an
  // uncaught error would otherwise vanish without a trace — historically
  // exactly how "the button does nothing" bugs hid here. Ship every error to
  // the native side's hw-debug.log through the hub relay.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    _sendHub(
      'debugLog',
      'FlutterError: ${details.exception}\n${details.stack}',
    );
    defaultOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _sendHub('debugLog', 'Uncaught: $error\n$stack');
    // Handled: logged is better than letting the zone kill this window's
    // event processing over one bad async path.
    return true;
  };
  runApp(
    ProviderScope(
      // Same rationale as the main isolate: git failures are deterministic,
      // surface them instead of hiding them behind Riverpod's default retry.
      retry: (_, _) => null,
      overrides: [
        // THE seam: every provider below GitService runs unchanged; only the
        // transport is swapped for the proxy. The exclusive-lane callback
        // marks our own-mutation tracker (so the forwarded watcher tick
        // doesn't double-refresh us) and tells the main window to refresh.
        activeExecutorProvider.overrideWith(
          (ref) => ProxyCommandExecutor(
            onMutationCompleted: (repoPath) {
              ref.read(ownMutationTrackerProvider).mark(repoPath);
              _sendHub('mutationPerformed', {'repoPath': repoPath});
            },
          ),
        ),
        // Identical construction to the production gitServiceProvider except
        // undo records are forwarded to the main window's journal — the
        // single source of undo truth (this window's ⌘Z executes against it
        // via `performUndo`; a journal split across isolates would drift).
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
              _sendHub('undoRecord', record.toJson());
              // The main window's post-mutation toast is journal-driven; our
              // journal lives over there, so raise the same "⌘Z to undo"
              // affordance directly — the mutation happened in THIS window.
              ref
                  .read(undoToastProvider.notifier)
                  .show(UndoToast(record.description, showUndoHint: true));
            },
          );
        }),
        // Defensive: nothing in HistoryView's graph watches this, but the
        // real implementation would call executeStream through the proxy and
        // throw. Watcher ticks arrive as pushed `repoTick` events instead.
        repoWatchProvider.overrideWith(
          (ref, repoPath) => const Stream<RepoWatchEvent>.empty(),
        ),
      ],
      child: const HistoryWindowApp(),
    ),
  );
}

/// The slice of the main window's connection state this window renders from.
/// Fed exclusively by the `requestState` handshake and pushed
/// `connectionChanged` events — the local `connectionProvider` sits inert.
class HistorySession {
  final ConnectionPhase phase;
  final ConnectionBackend backend;
  final String? repoPath;
  final String? connectionLabel;

  const HistorySession({
    this.phase = ConnectionPhase.disconnected,
    this.backend = ConnectionBackend.ssh,
    this.repoPath,
    this.connectionLabel,
  });

  bool get isConnected => phase == ConnectionPhase.connected;
}

class HistorySessionNotifier extends Notifier<HistorySession> {
  @override
  HistorySession build() => const HistorySession();

  void apply(ConnectionEventPayload payload) {
    state = HistorySession(
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

final historySessionProvider =
    NotifierProvider<HistorySessionNotifier, HistorySession>(
      HistorySessionNotifier.new,
    );

/// Diagnostics (gated by [kHistoryWindowDiagnostics]): route-level breadcrumbs
/// so hw-debug.log shows whether a tapped control's menu/sheet route actually
/// pushed. Installed only when the flag is on.
class _HubLogNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sendHub('debugLog', 'route push: ${route.runtimeType}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sendHub('debugLog', 'route pop: ${route.runtimeType}');
  }
}

class HistoryWindowApp extends StatelessWidget {
  const HistoryWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MacosApp(
      title: 'History — Magic Git',
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      navigatorObservers: kHistoryWindowDiagnostics
          ? [_HubLogNavigatorObserver()]
          : const <NavigatorObserver>[],
      home: const HistoryWindowShell(),
    );
  }
}

/// Owns the hub handler and the session lifecycle: installs the handler,
/// announces `ready` (revealing the native window), requests the initial
/// connection snapshot, and translates pushed events into provider
/// invalidations — the same refresh semantics the in-app History tab gets
/// from the live watcher and mutation call sites.
class HistoryWindowShell extends ConsumerStatefulWidget {
  const HistoryWindowShell({super.key});

  @override
  ConsumerState<HistoryWindowShell> createState() => _HistoryWindowShellState();
}

class _HistoryWindowShellState extends ConsumerState<HistoryWindowShell>
    with SingleTickerProviderStateMixin {
  /// Same suppression window as the repo panel's watcher listener: a tick
  /// arriving within this of our own mutation is that mutation's echo.
  static const _ownMutationSuppressWindow = Duration(seconds: 3);

  /// The Recovery sheet's live route while it's open — same provider-driven
  /// route pattern as AppShell's `_recoveryRoute`, so the filter-bar button
  /// and Esc/X can never disagree about visibility.
  ModalRoute<void>? _recoveryRoute;

  /// Debounces the settings→main sync for edits ORIGINATING in this window
  /// (the zoom gestures and the diff word-wrap toggle). Zoom fires dozens of
  /// [AppSettingsNotifier.setHistoryZoom] calls (each persisting to disk), so
  /// the main isolate should reload once, after the burst — and strictly after
  /// the last write has landed, which the debounce slack covers.
  Timer? _settingsSyncDebounce;

  // Diagnostics (gated by kHistoryWindowDiagnostics): a 300ms animation
  // measured after 2s — if `value` isn't 1.0/completed, this engine's vsync
  // never drives tickers, which is exactly the "pushed routes stay at their
  // opacity-0 entrance frame" failure. The frame-timings samples separate "no
  // frames at all" from "frames tick but animation clocks are frozen".
  AnimationController? _vsyncProbe;
  Timer? _vsyncProbeTimer;
  TimingsCallback? _timingsProbe;
  int _timingsSeen = 0;

  @override
  void initState() {
    super.initState();
    _hub.setMethodCallHandler(_onHubCall);
    if (kHistoryWindowDiagnostics) {
      _vsyncProbe = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      )..forward();
      _timingsProbe = (List<FrameTiming> timings) {
        if (_timingsSeen >= 2) return;
        _timingsSeen++;
        final t = timings.first;
        _sendHub(
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
        _sendHub(
          'debugLog',
          'vsync probe: ${probe.status.name} value=${probe.value} '
          'mouseConnected=${RendererBinding.instance.mouseTracker.mouseIsConnected}',
        );
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Reveal the native window only once real content exists (it opens at
      // alpha 0 — same flash-free dance as the main window).
      _sendHub('ready');
      // Pull the initial snapshot rather than waiting for a push — pushes
      // sent before this handler existed were dropped by design.
      try {
        final reply = await _hub.invokeMethod<Map<Object?, Object?>>(
          'requestState',
        );
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
        // Settings are SharedPreferences-backed and each isolate caches its
        // own copy — reload from disk so mid-session changes made in the
        // main window (committer identity, timeouts) apply to the next
        // command here instead of drifting until reopen.
        await ref.read(appSettingsProvider.notifier).reloadFromDisk();
    }
    return null;
  }

  void _applySession(ConnectionEventPayload payload) {
    final previous = ref.read(historySessionProvider);
    ref.read(historySessionProvider.notifier).apply(payload);
    final session = ref.read(historySessionProvider);

    if (session.phase == ConnectionPhase.disconnected) {
      // The window follows the session — nothing meaningful to show once the
      // session is gone. Swift closes us and notifies the bridge.
      _sendHub('closeSelf');
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
      // An open Recovery sheet targets the old repo — close it rather than
      // show stale refs under a new title.
      ref.read(recoveryVisibleProvider.notifier).setVisible(false);
    }
    final repoName = session.repoPath?.split('/').last;
    _sendHub(
      'setWindowTitle',
      repoName == null
          ? 'History'
          : 'History — $repoName'
                '${session.connectionLabel == null ? '' : ' (${session.connectionLabel})'}',
    );
  }

  /// ⌘Z (and the toast's click target): the journal lives in the main
  /// isolate, so the actual undo runs there via `performUndo`; every piece of
  /// UI it needs (dirty-overwrite confirm, stale/error dialogs, the "Undid:"
  /// toast) renders here — the window the user is looking at.
  Future<void> _undoGitOperation() async {
    // In-field ⌘Z must stay text undo — same backstop as AppShell.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorStateOfType<EditableTextState>() != null)) {
      return;
    }
    final repoPath = ref.read(historySessionProvider).repoPath;
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
          'The repository has changed since "$description" — this undo is '
          'no longer safe and has been discarded.',
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

  /// The main isolate already refreshed its own providers as part of the
  /// undo; mirror that here (the forwarded watcher tick would catch up
  /// eventually, but immediate is what the user expects mid-gaze).
  void _refreshAfterUndo(String repoPath) {
    ref.read(ownMutationTrackerProvider).mark(repoPath);
    noteWorktreeEdit(repoPath);
    _invalidateRepoFamilies(repoPath);
  }

  /// The one invalidation set every refresh path here shares — tick, undo,
  /// and Recovery restores all agree, so an open Recovery sheet can never
  /// show a pre-mutation reflog. Invalidating unwatched families is free.
  void _invalidateRepoFamilies(String repoPath) {
    for (final p in repoMutationFamilies(repoPath)) {
      ref.invalidate(p);
    }
  }

  void _onRepoTick(Map<Object?, Object?> args) {
    final repoPath = args['repoPath'] as String?;
    if (repoPath == null ||
        repoPath != ref.read(historySessionProvider).repoPath) {
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
    // tick is this window's ONLY freshness signal for main-window mutations —
    // every mutation there produces one.
    _invalidateRepoFamilies(repoPath);
  }

  @override
  Widget build(BuildContext context) {
    // The Recovery sheet opens locally in this window (full parity with the
    // in-app History tab) — the reflog/snapshot reads and restore actions all
    // flow through the same proxied executor as everything else here.
    ref.listen(recoveryVisibleProvider, (_, visible) {
      final repoPath = ref.read(historySessionProvider).repoPath;
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
    // all persisted from this isolate) must tell the main isolate to reload
    // its own SharedPreferences cache. Gated on a value *change* via a record
    // select — records compare by value, so the main window's settingsChanged
    // push (whose reload re-lands the same values here) can't ping-pong back.
    ref.listen(
      appSettingsProvider.select((s) => (s.historyZoom, s.historyDiffWrap)),
      (_, _) {
        _settingsSyncDebounce?.cancel();
        _settingsSyncDebounce = Timer(const Duration(milliseconds: 600), () {
          _sendHub('settingsChanged');
        });
      },
    );
    final session = ref.watch(historySessionProvider);
    final typography = MacosTheme.of(context).typography;
    // During a drop (`lost`) keep the history visible under a banner —
    // frozen-but-readable beats a blank window while auto-reconnect runs;
    // proxied commands fail fast with the dialogs users already know.
    final showBody =
        session.repoPath != null &&
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
        // Diagnostics (gated by kHistoryWindowDiagnostics): proves whether
        // clicks reach this Flutter view at all, and where. Null handler when
        // off — the Listener is then an inert passthrough.
        child: Listener(
          onPointerDown: kHistoryWindowDiagnostics
              ? (event) => _sendHub(
                  'debugLog',
                  'pointerDown ${event.position.dx.round()},'
                      '${event.position.dy.round()}',
                )
              : null,
          child: MacosWindow(
            child: ContentArea(
              builder: (context, _) => Stack(
                children: [
                  !showBody
                      ? Center(
                          child: Text(
                            'Waiting for session…',
                            style: typography.body.copyWith(
                              color: MacosColors.systemGrayColor,
                            ),
                          ),
                        )
                      : Column(
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
                              child: HistoryView(
                                repoPath: session.repoPath!,
                                isActive: true,
                              ),
                            ),
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
}
