import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:window_manager/window_manager.dart';
import '../core/output/output_log.dart';
import '../core/providers/app_providers.dart';
import '../core/settings/keymap.dart';
import '../core/ssh/host_key_prompt.dart';
import 'branches/branches_view.dart';
import 'common/branch_switch.dart';
import 'common/command_palette.dart';
import 'common/diff_view.dart' show kDiffMono;
import 'common/escape_dismissible.dart';
import 'common/sidebar_branding.dart';
import 'connection/connection_landing.dart';
import 'gitlab/gitlab_panel.dart';
import 'gitlab/project_panel.dart';
import 'history/history_view.dart';
import 'repository/repo_status_view.dart';
import 'settings/keyboard_shortcuts_sheet.dart';
import 'settings/settings_sheet.dart';
import 'stash/stash_view.dart';
import 'switcher/connection_switcher.dart';
import 'switcher/current_repo_indicator.dart';
import 'viewer/viewer_host.dart';
import 'viewer/viewer_providers.dart';

/// Top-level window shell. Content is driven by connection state: the
/// connection form until a session is established, then the feature panels
/// (Status, History, Branches, GitLab, Project) selected from the sidebar.
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
    windowManager.removeListener(this);
    super.dispose();
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
      builder: (_) => const KeyboardShortcutsSheet(),
    );
  }

  void _openConnections(BuildContext context) {
    showMacosSheet<void>(
      context: context,
      builder: (_) => const EscapeDismissible(child: ConnectionsPanel()),
    );
  }

  void _openPalette(BuildContext context) {
    final repoPath = ref.read(connectionProvider).repoPath;
    if (repoPath == null) return;
    showMacosSheet<void>(
      context: context,
      builder: (_) => CommandPalette(
        repoPath: repoPath,
        onGoToPanel: _selectPage,
        onRefresh: _refresh,
        onOpenSettings: () => _openSettings(context),
        onOpenShortcuts: () => _openShortcuts(context),
        onOpenConnections: () => _openConnections(context),
        onCheckoutBranch: (branch) => _checkoutBranch(context, repoPath, branch),
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
  /// Providers keyed purely by `repoPath` are invalidated by key; ones keyed
  /// by a compound record (a file path, a commit hash, a job id, …) are
  /// invalidated as a whole family instead — there's no single "currently
  /// selected" key to reconstruct here, and re-fetching a rarely-open pane
  /// for another repo is a negligible cost for a manual, occasional action.
  /// [repoWatchProvider] and [jobTraceProvider] are deliberately excluded:
  /// they're live subscriptions (a filesystem watcher, a streaming job log),
  /// not one-shot fetches, so invalidating them would just restart an
  /// already-current stream for no benefit.
  void _refresh() {
    final connection = ref.read(connectionProvider);
    final repo = connection.repoPath;
    if (repo == null || !connection.isConnected) return;
    ref.invalidate(statusProvider(repo));
    ref.invalidate(pendingOpProvider(repo));
    ref.invalidate(logProvider(repo));
    ref.invalidate(logSearchProvider);
    ref.invalidate(refsProvider(repo));
    ref.invalidate(stashesProvider(repo));
    ref.invalidate(stashDiffProvider);
    ref.invalidate(prepareCommitMsgHookProvider(repo));
    ref.invalidate(repoStructureProvider(repo));
    ref.invalidate(repoStatusOverlayProvider(repo));
    ref.invalidate(fileLogProvider);
    ref.invalidate(blameProvider);
    ref.invalidate(fileDiffProvider);
    ref.invalidate(commitDiffProvider);
    ref.invalidate(commitFileDiffProvider);
    ref.invalidate(conflictFileProvider);
    ref.invalidate(untrackedDiffProvider);
    ref.invalidate(mergeRequestsProvider(repo));
    ref.invalidate(pipelinesProvider(repo));
    ref.invalidate(jobsProvider);
    ref.invalidate(projectDashboardProvider(repo));
    // Re-read any open file viewer so a manual refresh reflects on-disk edits;
    // keyed by (repoPath, path), so the whole family is invalidated (there's no
    // single "current" key). Cheap — a closed viewer isn't watching, and an open
    // one costs one `cat`.
    ref.invalidate(fileContentProvider);
    ref.invalidate(fileBytesProvider);
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

    // Keep the native menu items' checkmarks in sync with the panel states.
    ref.listen(outputLogProvider.select((s) => s.visible), (_, visible) {
      _syncMenuState('setOutputViewChecked', visible);
    });
    ref.listen(fileViewVisibleProvider, (_, visible) {
      _syncMenuState('setFileViewChecked', visible);
    });
    // A background (non-active) page's panel is kept alive across tab
    // switches for the *same* repo, but must not silently carry a previous
    // repo's selections/scroll position/in-flight guards into a newly
    // switched-to repo — the active tab already guards against this itself
    // (e.g. GitLabPanel.didUpdateWidget), but the other five don't, so drop
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
        // top layer rather than inside any single panel.
        child: Stack(
          children: [
            _buildWindow(context, connection, connected),
            const Positioned.fill(child: ViewerHost()),
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
                label: Text('GitLab'),
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
          return IndexedStack(
            index: _pageIndex,
            children: [
              _visitedPages.contains(0)
                  ? RepoStatusView(
                      repoPath: repoPath,
                      isActive: _pageIndex == 0,
                    )
                  : const SizedBox.shrink(),
              _visitedPages.contains(1)
                  ? HistoryView(repoPath: repoPath, isActive: _pageIndex == 1)
                  : const SizedBox.shrink(),
              _visitedPages.contains(2)
                  ? BranchesView(repoPath: repoPath, isActive: _pageIndex == 2)
                  : const SizedBox.shrink(),
              _visitedPages.contains(3)
                  ? StashView(repoPath: repoPath, isActive: _pageIndex == 3)
                  : const SizedBox.shrink(),
              _visitedPages.contains(4)
                  ? GitLabPanel(repoPath: repoPath, isActive: _pageIndex == 4)
                  : const SizedBox.shrink(),
              _visitedPages.contains(5)
                  ? ProjectPanel(repoPath: repoPath)
                  : const SizedBox.shrink(),
            ],
          );
        },
      ),
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
