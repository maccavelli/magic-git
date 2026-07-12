import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:window_manager/window_manager.dart';
import '../core/git/git_service.dart';
import '../core/output/output_log.dart';
import '../core/providers/app_providers.dart';
import '../core/providers/window_manager_bridge.dart';
import '../core/settings/keymap.dart';
import '../core/ssh/host_key_prompt.dart';
import '../core/undo/undo_controller.dart';
import 'branches/branches_view.dart';
import 'common/actions.dart';
import 'common/branch_switch.dart';
import 'common/command_palette.dart';
import 'common/diff_view.dart' show kDiffMono;
import 'common/escape_dismissible.dart';
import 'common/sidebar_branding.dart';
import 'common/undo_toast.dart';
import 'connection/connection_landing.dart';
import 'dashboard/dashboard_sheet.dart';
import 'forge/forge_panel.dart';
import 'forge/forge_project_panel.dart';
import 'history/history_view.dart';
import 'recovery/recovery_sheet.dart';
import 'repository/repo_status_view.dart';
import 'settings/keyboard_shortcuts_sheet.dart';
import 'settings/settings_sheet.dart';
import 'settings/tool_health_banner.dart';
import 'stash/stash_view.dart';
import 'switcher/connection_switcher.dart';
import 'switcher/current_repo_indicator.dart';
import 'viewer/viewer_host.dart';
import 'viewer/viewer_providers.dart';
import 'workspace/clone_sheet.dart';
import 'workspace/create_repo_sheet.dart';

/// Top-level window shell. Content is driven by connection state: the
/// connection form until a session is established, then the feature panels
/// (Status, History, Branches, Stashes, Forge, Project) selected from the
/// sidebar.
/// The native window title: `repo (branch) — Magic Git` while a repo is
/// active, plain `Magic Git` otherwise. Shown in Mission Control, the app
/// switcher, and the Window menu (the in-window titlebar is hidden), so it's
/// how a user tells two projects apart at the OS level.
final _windowTitleProvider = Provider.autoDispose<String>((ref) {
  final connection = ref.watch(connectionProvider);
  final repoPath = connection.repoPath;
  if (!connection.isConnected || repoPath == null) return 'Magic Git';
  final segments = repoPath.split('/').where((seg) => seg.isNotEmpty);
  final name = segments.isEmpty ? repoPath : segments.last;
  final branch = ref.watch(
    statusProvider(repoPath).select((s) => s.value?.branch.head),
  );
  return branch == null || branch.isEmpty
      ? '$name — Magic Git'
      : '$name ($branch) — Magic Git';
});

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

/// A small popup shown over a dimmed backdrop when the SSH transport drops
/// mid-session. It reports the disconnect, shows the auto-reconnect attempt
/// counter, a spinner, and a live elapsed timer, and offers two distinct exits:
/// **Stop Retrying** pauses the auto-reconnect loop but keeps the session
/// resumable (the connection landing page then offers a one-click Reconnect),
/// while **Cancel** fully disconnects and returns to the plain connection card.
class _ReconnectingOverlay extends StatefulWidget {
  final String? host;
  final int attempt;
  final VoidCallback onStopRetrying;
  final VoidCallback onCancel;

  const _ReconnectingOverlay({
    required this.host,
    required this.attempt,
    required this.onStopRetrying,
    required this.onCancel,
  });

  @override
  State<_ReconnectingOverlay> createState() => _ReconnectingOverlayState();
}

class _ReconnectingOverlayState extends State<_ReconnectingOverlay> {
  Timer? _ticker;
  int _elapsed = 0; // seconds since the drop was first shown

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _elapsed++),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _elapsedLabel {
    final m = _elapsed ~/ 60;
    final s = _elapsed % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final brightness = MacosTheme.brightnessOf(context);
    return ColoredBox(
      color: MacosColors.black.withValues(alpha: 0.25),
      child: Center(
        child: Container(
          width: 340,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          decoration: BoxDecoration(
            color: brightness.resolve(
              CupertinoColors.systemGrey6.color,
              MacosColors.controlBackgroundColor.darkColor,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MacosColors.separatorColor),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MacosIcon(
                CupertinoIcons.wifi_exclamationmark,
                size: 44,
                color: MacosColors.systemOrangeColor,
              ),
              const SizedBox(height: 12),
              Text('Connection interrupted', style: typography.title3),
              const SizedBox(height: 6),
              Text(
                widget.host == null
                    ? 'The SSH connection dropped.'
                    : 'Lost contact with ${widget.host}.',
                textAlign: TextAlign.center,
                style: typography.body.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ProgressCircle(),
                  const SizedBox(width: 10),
                  Text(
                    widget.attempt > 0
                        ? 'Reconnecting… (attempt ${widget.attempt})'
                        : 'Reconnecting…',
                    style: typography.body,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Disconnected for $_elapsedLabel',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: widget.onStopRetrying,
                      child: const Text('Stop Retrying'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PushButton(
                      controlSize: ControlSize.large,
                      onPressed: widget.onCancel,
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener {
  int _pageIndex = 0;

  /// Which sidebar pages have been visited at least once since the current
  /// repo connected. A visited page's panel widget is kept alive in the
  /// [IndexedStack] (preserving scroll position, selections, in-flight
  /// guards, etc.) across tab switches instead of being torn down and
  /// rebuilt from scratch every time; an unvisited page renders a cheap
  /// placeholder so its panel — and the provider fetches its `build()` would
  /// trigger — doesn't run until the user actually opens that tab.
  final Set<int> _visitedPages = {0};

  /// Whether the host-key mismatch dialog is currently on screen. The
  /// dialog's non-dismissible full-window barrier already blocks every UI
  /// path that could otherwise clear the prompt out from under it, but this
  /// lets the listener below defensively pop it too if `hostKeyPrompt` is
  /// ever cleared some other way (e.g. a future disconnect path) while it's
  /// still showing, rather than leaving a stale dialog on screen.
  bool _hostKeyDialogOpen = false;

  /// The route the host-key dialog was pushed onto, captured when it's built so
  /// the listener can pop *exactly* that route — and only while it's still the
  /// current (top-most) one. Relying on [_hostKeyDialogOpen] alone risked a
  /// second, underlying route being popped if the prompt cleared after the
  /// dialog had already been dismissed but before the bool was reset.
  ModalRoute<dynamic>? _hostKeyDialogRoute;

  /// Bridge to the native menu bar. The Swift side ("View → Show Output View")
  /// invokes `toggleOutputView`; we push the current checkbox state back with
  /// `setOutputViewChecked` so the menu item's checkmark stays in sync.
  static const _menuChannel = MethodChannel('magicgit/menu');

  /// Debounces persisting the window's bounds while it's moved/resized. Saving
  /// continuously (rather than only on close/quit) is what makes the restore
  /// reliable: ⌘Q is intercepted (`prepareToTerminate`) and the red button
  /// fires [onWindowClose], but a crash or force-kill fires neither, and even
  /// a clean close's single final write can be lost to the process dying
  /// before it flushes. By the time the app exits, the last position/size is
  /// already persisted. See WindowBoundsStore and main.dart's restore.
  Timer? _boundsSaveTimer;

  /// The dashboard sheet's live route while it's open — how the
  /// menu-uncheck path closes exactly that route (and only it). Null when
  /// the dashboard is closed.
  ModalRoute<void>? _dashboardRoute;
  ModalRoute<void>? _recoveryRoute;

  @override
  void initState() {
    super.initState();
    _menuChannel.setMethodCallHandler(_handleMenuCall);
    // Push the initial (on-by-default) panel states so the native menu
    // checkmarks are correct from the first frame; ref.listen only fires on
    // subsequent changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncMenuState(
        'setOutputViewChecked',
        ref.read(outputLogProvider).visible,
      );
      _syncMenuState('setFileViewChecked', ref.read(fileViewVisibleProvider));
      _syncMenuState('setDashboardChecked', ref.read(dashboardVisibleProvider));
      // Initial title; ref.listen (in build) only fires on subsequent changes.
      unawaited(windowManager.setTitle(ref.read(_windowTitleProvider)));
    });
    // Intercept the window close so the SSH connection gets a clean
    // disconnect instead of the socket just vanishing when the process dies.
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    // Detach the native menu handler so a late `toggleOutputView`/`toggleFileView`
    // from Swift can't invoke `_handleMenuCall` (and touch a disposed `ref`).
    _menuChannel.setMethodCallHandler(null);
    _boundsSaveTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMoved() => _persistBoundsSoon();

  @override
  void onWindowResized() => _persistBoundsSoon();

  /// Persist the window's current bounds shortly after it settles. Debounced so
  /// a drag/resize that emits a burst of events writes once, not on every tick.
  void _persistBoundsSoon() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      // A minimized or full-screen frame isn't where the user wants the window
      // to reopen, so don't persist those transient bounds.
      if (await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      final bounds = await windowManager.getBounds();
      await WindowBoundsStore.save(
        bounds.left,
        bounds.top,
        bounds.width,
        bounds.height,
      );
    });
  }

  @override
  void onWindowClose() async {
    if (!await windowManager.isPreventClose()) return;
    // Capture bounds before the window actually closes so the next launch can
    // restore this position/size instead of always centering at the
    // hardcoded default (see WindowBoundsStore / main.dart).
    final bounds = await windowManager.getBounds();
    await WindowBoundsStore.save(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    );
    await ref.read(connectionProvider.notifier).disconnect();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Future<dynamic> _handleMenuCall(MethodCall call) async {
    // A menu call can still be dispatched during teardown; touching `ref` after
    // disposal throws, so bail once unmounted.
    if (!mounted) return null;
    switch (call.method) {
      case 'toggleOutputView':
        ref.read(outputLogProvider.notifier).toggle();
      case 'toggleFileView':
        ref.read(fileViewVisibleProvider.notifier).toggle();
      case 'toggleDashboard':
        ref.read(dashboardVisibleProvider.notifier).toggle();
      case 'toggleRecovery':
        ref.read(recoveryVisibleProvider.notifier).toggle();
      case 'openHistoryWindow':
        await ref.read(windowManagerBridgeProvider.notifier).openHistory();
      case 'prepareToTerminate':
        // ⌘Q (or any AppKit terminate path). The delegate holds termination
        // open (.terminateLater, with a native timeout backstop) until this
        // returns, so mirror onWindowClose: persist the final bounds and close
        // the SSH session cleanly instead of letting the process die with the
        // socket open.
        _boundsSaveTimer?.cancel();
        try {
          final bounds = await windowManager.getBounds();
          await WindowBoundsStore.save(
            bounds.left,
            bounds.top,
            bounds.width,
            bounds.height,
          );
        } catch (_) {
          // Best-effort — never block quitting on a bounds read.
        }
        if (mounted) {
          await ref.read(connectionProvider.notifier).disconnect();
        }
      case 'syncMenuState':
        // The native side asks for this once its menu items are installed, so
        // the checkmarks are correct even if our startup push (below) raced the
        // item creation and was dropped.
        _syncMenuState(
          'setOutputViewChecked',
          ref.read(outputLogProvider).visible,
        );
        _syncMenuState('setFileViewChecked', ref.read(fileViewVisibleProvider));
        _syncMenuState(
          'setDashboardChecked',
          ref.read(dashboardVisibleProvider),
        );
        _syncMenuState('setRecoveryChecked', ref.read(recoveryVisibleProvider));
    }
    return null;
  }

  void _syncMenuState(String method, bool visible) {
    _menuChannel.invokeMethod<void>(method, visible).catchError((_) {});
  }

  /// Switches the active sidebar page — shared by the sidebar's own tap
  /// handler and the ⌘1–⌘6 shortcuts below, so both paths mark the page
  /// visited the same way.
  void _selectPage(int index) {
    setState(() {
      _pageIndex = index;
      _visitedPages.add(index);
    });
  }

  void _openSettings(BuildContext context) {
    showMacosSheet<void>(
      context: context,
      builder: (_) => const EscapeDismissible(child: SettingsSheet()),
    );
  }

  void _openShortcuts(BuildContext context) {
    showMacosSheet<void>(
      context: context,
      builder: (_) =>
          const EscapeDismissible(child: KeyboardShortcutsSheet()),
    );
  }

  void _openConnections(BuildContext context) {
    showMacosSheet<void>(
      context: context,
      builder: (_) => const EscapeDismissible(child: ConnectionsPanel()),
    );
  }

  /// Palette entries — the sheets adapt to the active workspace (connected
  /// mode) and own their Escape handling, so no EscapeDismissible wrapper.
  void _openCloneRepository(BuildContext context) {
    final connected = ref.read(connectionProvider).isConnected;
    showMacosSheet<void>(
      context: context,
      builder: (_) => connected
          ? const CloneRepositorySheet.connected()
          : const CloneRepositorySheet.landing(),
    );
  }

  void _openCreateRepository(BuildContext context) {
    final connected = ref.read(connectionProvider).isConnected;
    showMacosSheet<void>(
      context: context,
      builder: (_) => connected
          ? const CreateRepositorySheet.connected()
          : const CreateRepositorySheet.landing(),
    );
  }

  void _openPalette(BuildContext context) {
    final repoPath = ref.read(connectionProvider).repoPath;
    if (repoPath == null) return;
    showMacosSheet<void>(
      context: context,
      builder: (_) => EscapeDismissible(
        child: CommandPalette(
          repoPath: repoPath,
          onGoToPanel: _selectPage,
          onRefresh: _refresh,
          onOpenSettings: () => _openSettings(context),
          onOpenShortcuts: () => _openShortcuts(context),
          onOpenConnections: () => _openConnections(context),
          onCloneRepository: () => _openCloneRepository(context),
          onCreateRepository: () => _openCreateRepository(context),
          onOpenHistoryWindow: () =>
              ref.read(windowManagerBridgeProvider.notifier).openHistory(),
          onCheckoutBranch: (branch) =>
              _checkoutBranch(context, repoPath, branch),
        ),
      ),
    );
  }

  Future<void> _checkoutBranch(
    BuildContext context,
    String repoPath,
    String branch,
  ) async {
    final git = ref.read(gitServiceProvider);
    await guardedBranchSwitch(
      context,
      ref,
      repoPath,
      () => git.checkout(repoPath, branch),
    );
    _refresh();
  }

  /// ⌘R: refresh every repo-scoped provider for the active repo. Invalidating a
  /// provider that isn't currently mounted is a harmless no-op, so one handler
  /// covers whichever page is showing.
  ///
  /// The list of families lives in [repoScopedFetchFamilies] — shared with
  /// the connection-reset path, so a new repo-scoped provider added there is
  /// automatically covered here too (the two lists drifted in the past and
  /// ⌘R silently skipped the GitHub panels). Whole-family invalidation is
  /// fine for a manual, occasional action: re-fetching a rarely-open pane for
  /// another repo is a negligible cost. The registry deliberately excludes
  /// the live subscriptions ([repoWatchProvider], [jobTraceProvider]) —
  /// invalidating those would just restart an already-current stream.
  void _refresh() {
    final connection = ref.read(connectionProvider);
    final repo = connection.repoPath;
    if (repo == null || !connection.isConnected) return;
    for (final family in repoScopedFetchFamilies) {
      ref.invalidate(family);
    }
    // Re-read any open file viewer so a manual refresh reflects on-disk edits.
    // These live in the viewer feature (the registry, in core, can't list
    // them). Cheap — a closed viewer isn't watching, and an open one costs
    // one `cat`.
    ref.invalidate(fileContentProvider);
    ref.invalidate(fileBytesProvider);
    // ⌘R covers the native History window too (no-op while it's closed).
    ref.read(windowManagerBridgeProvider.notifier).invalidateAllFor(repo);
  }

  /// ⌘Z (and the toast's click target): undo the most recent undoable git
  /// operation for the active repo. Success is announced as a toast, with a
  /// matching output-log line for the transcript.
  Future<void> _undoGitOperation() async {
    // In-field ⌘Z must stay text undo. A focused field's own text-editing
    // shortcuts consume the key before it bubbles up to the app-level
    // CallbackShortcuts; this guard is the backstop for focus setups that
    // don't (custom fields, platform quirks).
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorStateOfType<EditableTextState>() != null)) {
      return;
    }
    final repoPath = ref.read(connectionProvider).repoPath;
    if (repoPath == null) return;

    final controller = ref.read(undoControllerProvider);
    try {
      var attempt = await controller.undo(repoPath);
      if (!mounted) return;
      if (attempt.status == UndoStatus.dirty) {
        final overwrite = await confirmAction(
          context,
          title: 'Files Changed Since',
          message:
              'Undoing "${attempt.record!.description}" would overwrite '
              'files that changed after the operation ran. Overwrite them?',
          confirmLabel: 'Overwrite',
          destructive: true,
        );
        if (!overwrite || !mounted) return;
        attempt = await controller.undo(repoPath, force: true);
        if (!mounted) return;
      }
      switch (attempt.status) {
        case UndoStatus.done:
          ref
              .read(undoToastProvider.notifier)
              .show(UndoToast('Undid: ${attempt.record!.description}'));
          ref
              .read(outputLogProvider.notifier)
              .logInfo('Undid: ${attempt.record!.description}');
        case UndoStatus.stale:
          await showErrorDialog(
            context,
            'The repository has changed since "${attempt.record!.description}" '
            '— this undo is no longer safe and has been discarded.',
          );
        case UndoStatus.nothingToUndo:
        case UndoStatus.blockedByPendingOp:
        case UndoStatus.dirty:
          // Nothing actionable: an empty journal is silent, a pending
          // merge/rebase already shows its own banner with abort/continue,
          // and a declined dirty-overwrite was handled above.
          break;
      }
    } on GitException catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, '$e');
    }
  }

  /// Shows the non-dismissible host-key-mismatch dialog. "Cancel Connection"
  /// is the primary (default/most prominent) button — the safe choice when a
  /// server's identity key unexpectedly changes should never be an accidental
  /// click-through, unlike this app's usual confirm/cancel dialogs where the
  /// requested action is the prominent one.
  void _showHostKeyPrompt(BuildContext context, HostKeyPrompt prompt) {
    _hostKeyDialogOpen = true;
    showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) {
        // Capture this dialog's own route so the listener can target it
        // precisely rather than blindly popping the navigator.
        _hostKeyDialogRoute = ModalRoute.of(dialogContext);
        return MacosAlertDialog(
          appIcon: const MacosIcon(
            CupertinoIcons.exclamationmark_shield_fill,
            size: 56,
            color: MacosColors.systemRedColor,
          ),
          title: const Text('Host Key Changed'),
          message: _HostKeyPromptMessage(prompt: prompt),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              ref.read(connectionProvider.notifier).rejectHostKeyChange();
            },
            child: const Text('Cancel Connection'),
          ),
          secondaryButton: PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            color: MacosColors.systemRedColor,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              ref.read(connectionProvider.notifier).acceptHostKeyChange();
            },
            child: const Text('Refresh Key and Continue'),
          ),
        );
      },
    ).then((_) {
      _hostKeyDialogOpen = false;
      _hostKeyDialogRoute = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final connected = connection.isConnected && connection.repoPath != null;

    // Keep the native-History-window plumbing alive for the app's lifetime:
    // the bridge serves the second window's proxied commands and events; the
    // forwarder relays watcher ticks to it while (and only while) it's open.
    ref.watch(windowManagerBridgeProvider);
    ref.watch(windowTickForwardersProvider);

    // Keep the native window title tracking the active repo/branch.
    ref.listen(_windowTitleProvider, (_, title) {
      unawaited(windowManager.setTitle(title));
    });
    // Keep the native menu items' checkmarks in sync with the panel states.
    ref.listen(outputLogProvider.select((s) => s.visible), (_, visible) {
      _syncMenuState('setOutputViewChecked', visible);
    });
    ref.listen(fileViewVisibleProvider, (_, visible) {
      _syncMenuState('setFileViewChecked', visible);
    });
    // The dashboard is a modal sheet driven by a provider so all three of
    // its controls stay in sync: the View-menu checkbox toggles the
    // provider; the sheet's X / Esc pop the route (whose completion resets
    // the provider); and unchecking the menu removes the live route.
    ref.listen(dashboardVisibleProvider, (_, visible) {
      _syncMenuState('setDashboardChecked', visible);
      if (visible && _dashboardRoute == null) {
        showMacosSheet<void>(
          context: context,
          builder: (sheetContext) {
            _dashboardRoute = ModalRoute.of(sheetContext);
            return const EscapeDismissible(child: DashboardSheet());
          },
        ).whenComplete(() {
          _dashboardRoute = null;
          if (mounted) {
            ref.read(dashboardVisibleProvider.notifier).setVisible(false);
          }
        });
      } else if (!visible && _dashboardRoute != null) {
        final route = _dashboardRoute!;
        _dashboardRoute = null;
        if (route.isCurrent) {
          Navigator.of(context, rootNavigator: true).pop();
        } else if (route.isActive) {
          // Buried under another sheet — remove just the dashboard.
          Navigator.of(context, rootNavigator: true).removeRoute(route);
        }
      }
    });
    // The Recovery sheet follows the Dashboard's provider-driven route
    // pattern exactly — see the comment above.
    ref.listen(recoveryVisibleProvider, (_, visible) {
      _syncMenuState('setRecoveryChecked', visible);
      if (visible && _recoveryRoute == null) {
        showMacosSheet<void>(
          context: context,
          builder: (sheetContext) {
            _recoveryRoute = ModalRoute.of(sheetContext);
            return const EscapeDismissible(child: RecoverySheet());
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
    // A background (non-active) page's panel is kept alive across tab
    // switches for the *same* repo, but must not silently carry a previous
    // repo's selections/scroll position/in-flight guards into a newly
    // switched-to repo — the active tab already guards against this itself
    // (e.g. the Forge panel's didUpdateWidget), but the other five don't, so drop
    // every non-active page back to unvisited here; each is rebuilt fresh
    // the next time it's opened.
    ref.listen(connectionProvider.select((c) => c.repoPath), (previous, next) {
      if (next != previous) {
        // Open file-viewer windows belong to the repo that was active when
        // they were opened — drop them all when the active repo changes (or
        // disconnects) rather than leaving them pointed at a gone repo.
        ref.read(openFileViewersProvider.notifier).closeAll();
      }
      if (next != null && next != previous) {
        setState(
          () => _visitedPages
            ..clear()
            ..add(_pageIndex),
        );
      }
    });
    // A changed host key pauses the in-progress connect/reconnect on an
    // explicit decision — surfaced as a non-dismissible modal regardless of
    // which flow triggered it (the initial connect form, a one-click "recent
    // connection", or a background auto-reconnect), since AppShell itself is
    // always mounted once past the very first launch frame.
    ref.listen(connectionProvider.select((c) => c.hostKeyPrompt), (
      previous,
      next,
    ) {
      if (next != null && previous == null) {
        _showHostKeyPrompt(context, next);
      } else if (next == null && _hostKeyDialogOpen) {
        // Pop only the dialog's own route, and only while it's still on top —
        // never an underlying page route if the dialog was already dismissed.
        final route = _hostKeyDialogRoute;
        if (route != null && route.isCurrent) {
          Navigator.of(context).pop();
        }
      }
    });

    final keymap = ref.watch(keymapProvider);
    final shortcuts = resolveShortcuts(keymap, {
      'global.refresh': _refresh,
      'global.openSettings': () => _openSettings(context),
      'global.showShortcuts': () => _openShortcuts(context),
      'global.commandPalette': connected ? () => _openPalette(context) : null,
      'global.undo': connected ? _undoGitOperation : null,
      'global.panel1': connected ? () => _selectPage(0) : null,
      'global.panel2': connected ? () => _selectPage(1) : null,
      'global.panel3': connected ? () => _selectPage(2) : null,
      'global.panel4': connected ? () => _selectPage(3) : null,
      'global.panel5': connected ? () => _selectPage(4) : null,
      'global.panel6': connected ? () => _selectPage(5) : null,
    });

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        // The file-viewer windows float above the whole app (sidebar +
        // content) and survive tab switches, so they're mounted here as the
        // top layer rather than inside any single panel. The undo toast sits
        // above even those — a transient announcement must never hide behind
        // a viewer window.
        child: Stack(
          children: [
            _buildWindow(context, connection, connected),
            const Positioned.fill(child: ViewerHost()),
            UndoToastOverlay(onUndo: _undoGitOperation),
          ],
        ),
      ),
    );
  }

  Widget _buildWindow(
    BuildContext context,
    ConnectionState connection,
    bool connected,
  ) {
    return MacosWindow(
      sidebar: Sidebar(
        minWidth: 240,
        maxWidth: 380,
        top: const SidebarBranding(),
        // The connections switcher only makes sense once connected — hide it on
        // the landing page.
        // Current-repository indicator sits directly above the connections
        // button so the active repo is always visible at a glance.
        bottom: connected
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CurrentRepoIndicator(),
                  ConnectionSwitcher(),
                  LogoutButton(),
                ],
              )
            : null,
        builder: (context, scrollController) {
          return SidebarItems(
            currentIndex: connected ? _pageIndex : 0,
            // While disconnected the content is pinned to ConnectionLanding, so
            // swallow sidebar taps rather than mutating the (hidden) page state.
            // (onChanged is non-nullable, so use a no-op instead of null.)
            onChanged: connected ? _selectPage : (_) {},
            items: const [
              SidebarItem(
                leading: MacosIcon(CupertinoIcons.folder),
                label: Text('Repository'),
              ),
              SidebarItem(
                leading: MacosIcon(CupertinoIcons.clock),
                label: Text('History'),
              ),
              SidebarItem(
                leading: MacosIcon(CupertinoIcons.arrow_branch),
                label: Text('Branches'),
              ),
              SidebarItem(
                leading: MacosIcon(CupertinoIcons.tray_2),
                label: Text('Stashes'),
              ),
              SidebarItem(
                leading: MacosIcon(CupertinoIcons.cloud),
                label: Text('Forge'),
              ),
              SidebarItem(
                leading: MacosIcon(CupertinoIcons.cube_box),
                label: Text('Project'),
              ),
            ],
          );
        },
      ),
      child: ContentArea(
        builder: (context, scrollController) {
          // A dropped connection auto-reconnects behind a small popup; Cancel
          // stops the retries and returns to the connection card.
          if (connection.reconnecting) {
            return _ReconnectingOverlay(
              host: connection.host,
              attempt: connection.reconnectAttempt,
              onStopRetrying: () =>
                  ref.read(connectionProvider.notifier).stopReconnect(),
              onCancel: () =>
                  ref.read(connectionProvider.notifier).disconnect(),
            );
          }
          if (!connected) {
            return const ConnectionLanding();
          }
          final repoPath = connection.repoPath!;
          // IndexedStack (rather than returning a single widget per index)
          // keeps a page's panel mounted once visited, so switching tabs
          // preserves its scroll position, selection, and in-flight-mutation
          // guards instead of tearing it down and re-fetching from scratch
          // every time. Unvisited pages stay a cheap placeholder — and never
          // trigger their panel's provider fetches — until first opened.
          // A missing-tool banner sits above every page (zero-height when the
          // host is healthy) so a gap in the environment is visible wherever
          // the user is, not just in Settings.
          return Column(
            children: [
              const ToolHealthBanner(),
              Expanded(child: _pages(repoPath)),
            ],
          );
        },
      ),
    );
  }

  Widget _pages(String repoPath) {
    return IndexedStack(
      index: _pageIndex,
      children: [
        _visitedPages.contains(0)
            ? RepoStatusView(repoPath: repoPath, isActive: _pageIndex == 0)
            : const SizedBox.shrink(),
        _visitedPages.contains(1)
            ? HistoryView(
                repoPath: repoPath,
                isActive: _pageIndex == 1,
                onPopOut: () =>
                    ref.read(windowManagerBridgeProvider.notifier).openHistory(),
              )
            : const SizedBox.shrink(),
        _visitedPages.contains(2)
            ? BranchesView(repoPath: repoPath, isActive: _pageIndex == 2)
            : const SizedBox.shrink(),
        _visitedPages.contains(3)
            ? StashView(repoPath: repoPath, isActive: _pageIndex == 3)
            : const SizedBox.shrink(),
        _visitedPages.contains(4)
            ? ForgePanel(repoPath: repoPath, isActive: _pageIndex == 4)
            : const SizedBox.shrink(),
        _visitedPages.contains(5)
            ? ForgeProjectPanel(repoPath: repoPath, isActive: _pageIndex == 5)
            : const SizedBox.shrink(),
      ],
    );
  }
}

/// The body of the host-key-mismatch dialog: a plain-language explanation of
/// what changed and why it matters, followed by the previously-trusted and
/// newly-presented key so the user can compare them (e.g. against a
/// fingerprint the server's administrator has shared through another
/// channel) before deciding.
class _HostKeyPromptMessage extends StatelessWidget {
  final HostKeyPrompt prompt;

  const _HostKeyPromptMessage({required this.prompt});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The identity key presented by ${prompt.host}:${prompt.port} does '
          'not match the one this app trusted the last time it connected '
          'here.',
          style: typography.body,
        ),
        const SizedBox(height: 10),
        Text(
          'This can happen after the server is reinstalled or its key is '
          'deliberately renewed. It can also mean someone is intercepting '
          'your connection. If you were not expecting this server to change, '
          'cancel and check with whoever administers it before continuing.',
          style: typography.body.copyWith(color: MacosColors.systemGrayColor),
        ),
        const SizedBox(height: 14),
        _fingerprintRow(
          context,
          'Previously trusted',
          prompt.previousKeyType,
          prompt.previousFingerprint,
        ),
        const SizedBox(height: 8),
        _fingerprintRow(
          context,
          'Now presented',
          prompt.newKeyType,
          prompt.newFingerprint,
          highlight: true,
        ),
      ],
    );
  }

  Widget _fingerprintRow(
    BuildContext context,
    String label,
    String keyType,
    String fingerprint, {
    bool highlight = false,
  }) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          '$keyType  $fingerprint',
          style: kDiffMono.copyWith(
            fontSize: 13,
            color: highlight ? MacosColors.systemRedColor : null,
          ),
        ),
      ],
    );
  }
}
