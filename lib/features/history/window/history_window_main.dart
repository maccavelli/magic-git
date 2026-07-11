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

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/exec/exec_proxy_codec.dart';
import '../../../core/exec/proxy_command_executor.dart';
import '../../../core/git/git_service.dart';
import '../../../core/git/watch_event.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../history_view.dart';

const _hub = MethodChannel('magicgit/history/hub');

/// Fire-and-forget sender for hub events. Errors (relay torn down mid-close)
/// are deliberately swallowed — an event that can't be delivered has no one
/// left to care about it.
void _sendHub(String method, [Object? arguments]) {
  _hub.invokeMethod<void>(method, arguments).catchError((_) {});
}

/// Entrypoint body — called by `historyWindowMain()` in `lib/main.dart`
/// (the `@pragma('vm:entry-point')` stub must live in the root library,
/// because macOS `FlutterEngine.run(withEntrypoint:)` resolves names there).
void runHistoryWindow() {
  WidgetsFlutterBinding.ensureInitialized();
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
        // undo records are forwarded to the main window's journal — ⌘Z lives
        // only there, and a journal split across isolates would be worse
        // than none.
        gitServiceProvider.overrideWith((ref) {
          final (commitTimeout, networkTimeout, committerName, committerEmail) =
              ref.watch(
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
            onUndoRecord: (record) => _sendHub('undoRecord', record.toJson()),
          );
        }),
        // The History filter bar's Recovery button keeps working untouched —
        // it now means "open the Recovery sheet in the main window".
        recoveryVisibleProvider.overrideWith(ForwardingRecoveryVisibility.new),
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

/// [RecoveryVisibility] that forwards "show" to the main window instead of
/// tracking local state — the Recovery sheet renders there, over the session
/// that owns the journal and snapshots.
class ForwardingRecoveryVisibility extends RecoveryVisibility {
  @override
  void setVisible(bool value) {
    if (value) _sendHub('openRecovery');
  }

  @override
  void toggle() => setVisible(true);
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

class _HistoryWindowShellState extends ConsumerState<HistoryWindowShell> {
  /// Same suppression window as the repo panel's watcher listener: a tick
  /// arriving within this of our own mutation is that mutation's echo.
  static const _ownMutationSuppressWindow = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _hub.setMethodCallHandler(_onHubCall);
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

  Future<Object?> _onHubCall(MethodCall call) async {
    switch (call.method) {
      case 'connectionChanged':
        _applySession(
          ConnectionEventPayload.decode(
            call.arguments as Map<Object?, Object?>,
          ),
        );
      case 'repoTick':
        _onRepoTick(call.arguments as Map<Object?, Object?>);
      case 'invalidateAll':
        for (final family in repoScopedFetchFamilies) {
          ref.invalidate(family);
        }
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

  void _onRepoTick(Map<Object?, Object?> args) {
    final repoPath = args['repoPath'] as String?;
    if (repoPath == null || repoPath != ref.read(historySessionProvider).repoPath) {
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
    // every mutation there produces one. Refresh the families History renders
    // from; the rest of the registry isn't mounted here.
    ref.invalidate(statusProvider(repoPath));
    ref.invalidate(logProvider(repoPath));
    ref.invalidate(refsProvider(repoPath));
    ref.invalidate(stashesProvider(repoPath));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(historySessionProvider);
    final typography = MacosTheme.of(context).typography;
    // During a drop (`lost`) keep the history visible under a banner —
    // frozen-but-readable beats a blank window while auto-reconnect runs;
    // proxied commands fail fast with the dialogs users already know.
    final showBody =
        session.repoPath != null &&
        (session.isConnected || session.phase == ConnectionPhase.lost);
    return MacosWindow(
      child: ContentArea(
        builder: (context, _) => !showBody
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
                        'Connection lost — reconnecting… actions will fail '
                        'until the session returns.',
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
      ),
    );
  }
}
