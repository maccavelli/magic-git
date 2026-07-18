import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/utils/display_error.dart';
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
import 'common/buttons.dart';
import 'common/command_palette.dart';
import 'common/diff_view.dart' show kDiffMono;
import 'common/escape_dismissible.dart';
import 'common/palette_intents.dart';
import 'common/sidebar_branding.dart';
import 'common/undo_toast.dart';
import 'connection/connection_landing.dart';
import 'dashboard/dashboard_sheet.dart';
import 'dnd/drop_registry.dart';
import 'dnd/nav_rail.dart';
import 'forge/forge_panel.dart';
import 'history/history_view.dart';
import 'recovery/recovery_sheet.dart';
import 'repository/repo_status_view.dart';
import 'settings/keyboard_shortcuts_sheet.dart';
import 'settings/settings_sheet.dart';
import 'settings/tool_health_banner.dart';
import 'stash/stash_view.dart';
import 'switcher/connection_switcher.dart';
import 'switcher/current_repo_indicator.dart';
import 'tabs/tab_ui_providers.dart';
import 'viewer/viewer_host.dart';
import 'viewer/viewer_providers.dart';
import 'workspace/clone_sheet.dart';
import 'workspace/create_repo_sheet.dart';
import 'worktrees/worktree_access.dart';
import 'worktrees/worktree_tabs.dart';
import 'worktrees/worktrees_view.dart';

/// Top-level per-tab content shell. Content is driven by connection state: the
/// connection form until a session is established, then the feature panels
/// (Status, History, Branches, Stashes, Forge, Worktrees) selected from the
/// sidebar.
///
/// Mounted by [TabsHost] inside the active tab's own [ProviderContainer], so
/// every `ref` here resolves against that tab's session. Process-level concerns
/// that must outlive tab switches — the native menu bridge, the window
/// lifecycle, and the window title — live in [TabsHost], not here.
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
                    child: AppPushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: widget.onStopRetrying,
                      child: const Text('Stop Retrying'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppPushButton(
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

class _AppShellState extends ConsumerState<AppShell> {
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

  /// The dashboard sheet's live route while it's open — how the
  /// menu-uncheck path closes exactly that route (and only it). Null when
  /// the dashboard is closed.
  ModalRoute<void>? _dashboardRoute;
  ModalRoute<void>? _recoveryRoute;

  /// Switches the active sidebar page — shared by the sidebar's own tap
  /// handler and the ⌘1–⌘6 shortcuts below, so both paths mark the page
  /// visited the same way. Page state lives in per-tab providers (retained
  /// while this tab is backgrounded), not widget State.
  void _selectPage(int index) {
    ref.read(pageIndexProvider.notifier).select(index);
    ref.read(visitedPagesProvider.notifier).visit(index);
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
      builder: (_) => const EscapeDismissible(child: KeyboardShortcutsSheet()),
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
          onOpenHistoryWindow: () => WindowManagerBridge.current?.openHistory(),
          onUndo: _undoGitOperation,
          onDispatchAction: _dispatchPaletteAction,
          onCheckoutBranch: (branch) =>
              _checkoutBranch(context, repoPath, branch),
          onOpenWorktree: (path) => _openWorktree(context, path),
        ),
      ),
    );
  }

  /// Runs a panel-scoped keymap action from the palette: switch to the owning
  /// panel, then park the action id as a [PaletteIntent] — the panel's
  /// [PanelShortcuts] consumes it on its next build and runs the exact
  /// handler (with all its guards) the keyboard shortcut would.
  void _dispatchPaletteAction(String actionId, int panelIndex) {
    _selectPage(panelIndex);
    ref.read(paletteIntentProvider.notifier).dispatch(actionId);
  }

  /// Opens a worktree in the Worktrees panel — the shared grant-then-open-
  /// then-navigate helper (see [switchToWorktree]).
  Future<void> _openWorktree(BuildContext context, String worktreePath) =>
      switchToWorktree(context, ref, worktreePath);

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
    WindowManagerBridge.current?.invalidateAllFor(repo);
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
      await showErrorDialog(context, displayError(e));
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
          primaryButton: AppPushButton(
            controlSize: ControlSize.large,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              ref.read(connectionProvider.notifier).rejectHostKeyChange();
            },
            child: const Text('Cancel Connection'),
          ),
          secondaryButton: AppPushButton(
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
    final pageIndex = ref.watch(pageIndexProvider);
    final visitedPages = ref.watch(visitedPagesProvider);

    // The single native-History-window bridge lives in the root container (kept
    // alive by main.dart), not here — watching windowManagerBridgeProvider from
    // a tab container would spin up a second, conflicting bridge. Pop-outs are
    // spawned via WindowManagerBridge.current below.

    // The dashboard is a modal sheet driven by a provider so all three of
    // its controls stay in sync: the View-menu checkbox toggles the
    // provider; the sheet's X / Esc pop the route (whose completion resets
    // the provider); and unchecking the menu removes the live route. The
    // menu-checkmark push itself lives in TabsHost (routed to the active tab).
    ref.listen(dashboardVisibleProvider, (_, visible) {
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
        // Same for worktree tabs: they name checkouts of the PREVIOUS repo.
        // Without this the Worktrees panel briefly renders the old repo's
        // workspace against the new repo (its build-time dead-tab sweep only
        // fires after the new worktree list loads — and never if it errors).
        // The sandbox grants they held go with them.
        ref.read(worktreeTabsProvider.notifier).reset();
        unawaited(ref.read(worktreeAccessProvider).releaseAll());
      }
      if (next != null && next != previous) {
        ref
            .read(visitedPagesProvider.notifier)
            .reset(ref.read(pageIndexProvider));
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
      'global.panel7': connected ? () => _selectPage(6) : null,
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
            _buildWindow(
              context,
              connection,
              connected,
              pageIndex,
              visitedPages,
            ),
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
    int pageIndex,
    Set<int> visitedPages,
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
          // A custom rail (not macos_ui SidebarItems) so each tab is an
          // individual drop target: items dragged from a panel can be dropped
          // on a tab to run a workflow (commit -> Branches, branch ->
          // Worktrees). Idle it mirrors the native item list.
          return NavRail(
            currentIndex: connected ? pageIndex : 0,
            // While disconnected the content is pinned to ConnectionLanding, so
            // swallow sidebar taps rather than mutating the (hidden) page state.
            onChanged: connected ? _selectPage : (_) {},
            controller: scrollController,
            selectPage: _selectPage,
            refresh: _refresh,
            items: const [
              NavRailItem(
                icon: CupertinoIcons.folder,
                label: 'Repository',
                zone: DropZoneId.repository,
              ),
              NavRailItem(
                icon: CupertinoIcons.clock,
                label: 'History',
                zone: DropZoneId.history,
              ),
              NavRailItem(
                icon: CupertinoIcons.arrow_branch,
                label: 'Branches',
                zone: DropZoneId.branches,
              ),
              NavRailItem(
                icon: CupertinoIcons.tray_2,
                label: 'Stashes',
                zone: DropZoneId.stashes,
              ),
              NavRailItem(
                icon: CupertinoIcons.cloud,
                label: 'Forge',
                zone: DropZoneId.forge,
              ),
              NavRailItem(
                icon: kWorktreeIcon,
                label: 'Worktrees',
                zone: DropZoneId.worktrees,
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
              Expanded(child: _pages(repoPath, pageIndex, visitedPages)),
            ],
          );
        },
      ),
    );
  }

  Widget _pages(String repoPath, int pageIndex, Set<int> visitedPages) {
    return IndexedStack(
      index: pageIndex,
      children: [
        visitedPages.contains(0)
            ? RepoStatusView(repoPath: repoPath, isActive: pageIndex == 0)
            : const SizedBox.shrink(),
        visitedPages.contains(1)
            ? HistoryView(
                repoPath: repoPath,
                isActive: pageIndex == 1,
                onPopOut: () => WindowManagerBridge.current?.openHistory(),
              )
            : const SizedBox.shrink(),
        visitedPages.contains(2)
            ? BranchesView(repoPath: repoPath, isActive: pageIndex == 2)
            : const SizedBox.shrink(),
        visitedPages.contains(3)
            ? StashView(repoPath: repoPath, isActive: pageIndex == 3)
            : const SizedBox.shrink(),
        visitedPages.contains(4)
            ? ForgePanel(repoPath: repoPath, isActive: pageIndex == 4)
            : const SizedBox.shrink(),
        visitedPages.contains(5)
            ? WorktreesView(repoPath: repoPath, isActive: pageIndex == 5)
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
