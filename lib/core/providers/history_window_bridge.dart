import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../exec/exec_proxy_codec.dart';
import '../git/watch_event.dart';
import '../undo/undo_journal.dart';
import '../undo/undo_types.dart';
import 'app_providers.dart';

/// Main-isolate end of the native History window: opens/closes the window
/// (via the Swift `magicgit/history` channel), serves the History isolate's
/// proxied git commands, absorbs its side effects (undo records, refresh
/// signals), and pushes session/watcher events to it — all over the
/// `magicgit/history/hub` relay.
///
/// State is "is the History window open" — the tick forwarder
/// ([historyTickForwarderProvider]) and event pushes key off it. Kept alive
/// by AppShell.
class HistoryWindowBridge extends Notifier<bool> {
  static const _control = MethodChannel('magicgit/history');
  static const _hub = MethodChannel('magicgit/history/hub');

  @override
  bool build() {
    _control.setMethodCallHandler(_onControlCall);
    _hub.setMethodCallHandler(_onHubCall);
    ref.onDispose(() {
      _control.setMethodCallHandler(null);
      _hub.setMethodCallHandler(null);
    });
    ref.listen(connectionProvider, _onConnectionChanged);
    return false;
  }

  /// Opens (or fronts) the native History window. No-op unless a repo is
  /// active — the window is a client of the live session.
  Future<void> open() async {
    final connection = ref.read(connectionProvider);
    if (!connection.isConnected || connection.repoPath == null) return;
    try {
      await _control.invokeMethod<void>('openHistoryWindow');
      // Optimistic: the authoritative signal is the window's own
      // requestState handshake; this just starts event pushes early.
      state = true;
    } catch (_) {
      // Missing handler / platform error — the window didn't open; stay
      // closed rather than pushing events into the void.
      state = false;
    }
  }

  Future<void> close() async {
    try {
      await _control.invokeMethod<void>('closeHistoryWindow');
    } on PlatformException {
      // Already gone.
    }
  }

  /// ⌘R parity: called from AppShell's refresh after the main-isolate
  /// invalidation loop, so a manual refresh covers both windows.
  void invalidateAllInHistory(String repoPath) {
    if (!state) return;
    _sendEvent('invalidateAll', {'repoPath': repoPath});
  }

  /// Forwards one watcher tick (subscription owned by
  /// [historyTickForwarderProvider]). Deliberately unsuppressed — the History
  /// isolate applies its own own-mutation logic.
  void forwardTick(String repoPath, RepoWatchEvent event) {
    if (!state) return;
    _sendEvent('repoTick', {
      'repoPath': repoPath,
      'mode': event.mode.name,
      'atMs': event.at.millisecondsSinceEpoch,
    });
  }

  Future<Object?> _onControlCall(MethodCall call) async {
    if (call.method == 'historyWindowClosed') state = false;
    return null;
  }

  void _onConnectionChanged(ConnectionState? previous, ConnectionState next) {
    if (!state) return;
    _sendEvent('connectionChanged', _snapshot(next).encode());
    if (next.phase == ConnectionPhase.disconnected) {
      // The window follows the session. The History isolate also asks Swift
      // to close it when it sees this event — both paths are idempotent.
      close();
    }
  }

  ConnectionEventPayload _snapshot(ConnectionState connection) =>
      ConnectionEventPayload(
        phase: connection.phase.name,
        backend: connection.backend.name,
        repoPath: connection.repoPath,
        connectionLabel: connection.connectionLabel,
        host: connection.host,
      );

  Future<Object?> _onHubCall(MethodCall call) async {
    switch (call.method) {
      case 'execute':
        final request = decodeExecuteRequest(
          call.arguments as Map<Object?, Object?>,
        );
        try {
          // Read per call so a backend switch mid-session is honored.
          final result = await ref
              .read(activeExecutorProvider)
              .execute(
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
        // The window exists and is asking — treat as open even if the
        // control-channel bookkeeping raced.
        state = true;
        return _snapshot(ref.read(connectionProvider)).encode();
      case 'undoRecord':
        final record = UndoRecord.fromJson(
          call.arguments as Map<Object?, Object?>,
        );
        // A null record means version skew — drop it; an un-runnable undo
        // is worse than a missing one. The journal push also triggers the
        // main window's toast (UndoToastOverlay is journal-listen-driven).
        if (record != null) {
          ref.read(undoJournalProvider.notifier).push(record);
        }
        return null;
      case 'mutationPerformed':
        final repoPath =
            (call.arguments as Map<Object?, Object?>)['repoPath'] as String?;
        if (repoPath != null) {
          // Same refresh contract as a local mutation call site: mark so the
          // watcher echo is suppressed, bump the edit generation so the
          // status memo can't swallow it, and refresh what History mutations
          // can change.
          ref.read(ownMutationTrackerProvider).mark(repoPath);
          noteWorktreeEdit(repoPath);
          ref.invalidate(statusProvider(repoPath));
          ref.invalidate(logProvider(repoPath));
          ref.invalidate(refsProvider(repoPath));
          ref.invalidate(stashesProvider(repoPath));
        }
        return null;
      case 'openRecovery':
        // Swift already fronted the main window before forwarding.
        ref.read(recoveryVisibleProvider.notifier).setVisible(true);
        return null;
    }
    return null;
  }

  void _sendEvent(String method, Object? arguments) {
    _hub.invokeMethod<void>(method, arguments).catchError((_) {});
  }
}

final historyWindowBridgeProvider = NotifierProvider<HistoryWindowBridge, bool>(
  HistoryWindowBridge.new,
);

/// Keeps the active repo's watcher alive and forwards its ticks to the
/// History window — but only while that window is open, so a closed window
/// costs nothing. Watched by AppShell alongside the bridge.
final historyTickForwarderProvider = Provider<void>((ref) {
  final isOpen = ref.watch(historyWindowBridgeProvider);
  final repoPath = ref.watch(
    connectionProvider.select((c) => c.isConnected ? c.repoPath : null),
  );
  if (!isOpen || repoPath == null) return;
  ref.listen(repoWatchProvider(repoPath), (previous, next) {
    final event = next.value;
    if (event == null) return;
    ref
        .read(historyWindowBridgeProvider.notifier)
        .forwardTick(repoPath, event);
  });
});
