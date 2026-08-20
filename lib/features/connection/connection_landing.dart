import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/hover_pop.dart';
import '../common/tappable.dart';
import '../switcher/connection_switcher.dart';
import 'local_repo_form.dart';

/// The landing (unconnected) page: a layered branding card with just two
/// actions — **Connections Manager** (the single entry point to every
/// workspace action: open a configured workspace, add SSH remotes and local
/// repositories, clone/create) and **Recent Repositories** (a pull-down of
/// the last few repos for a one-tap reopen). Reflects connect
/// progress/errors for the recent-connect path.
class ConnectionLanding extends ConsumerWidget {
  const ConnectionLanding({super.key});

  /// One entry point for everything workspace-related: the Connections
  /// Manager lists the configured connections/local repos (click to open)
  /// and its toolbar adds SSH remotes and local repositories or clones/
  /// creates repositories — the landing itself stays a single clear action.
  void _openConnectionsManager(BuildContext context) {
    showMacosSheet<void>(
      context: context,
      builder: (_) => const EscapeDismissible(child: ConnectionsPanel()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (phase, host, connectionError) = ref.watch(
      connectionProvider.select((c) => (c.phase, c.host, c.error)),
    );
    final typography = MacosTheme.of(context).typography;

    if (phase == ConnectionPhase.connecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ProgressCircle(),
            const SizedBox(height: 14),
            Text(
              host == null ? 'Connecting…' : 'Connecting to $host…',
              style: typography.body.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      );
    }

    // Auto-reconnect was paused (via "Stop Retrying" in the reconnect popup)
    // rather than fully disconnected — the session is still resumable in one
    // click via `reconnect()`, which reuses the retained profile/repo.
    if (phase == ConnectionPhase.lost) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MacosIcon(
                CupertinoIcons.wifi_exclamationmark,
                size: 40,
                color: MacosColors.systemGrayColor,
              ),
              const SizedBox(height: 14),
              Text('Connection lost', style: typography.title3),
              const SizedBox(height: 6),
              Text(
                host == null
                    ? 'Auto-reconnect was stopped.'
                    : 'Auto-reconnect to $host was stopped.',
                textAlign: TextAlign.center,
                style: typography.body.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              if (connectionError != null &&
                  connectionError != 'Connection lost') ...[
                const SizedBox(height: 6),
                Text(
                  connectionError,
                  textAlign: TextAlign.center,
                  style: typography.body.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: HoverPop(
                  child: AppPushButton(
                    controlSize: ControlSize.large,
                    onPressed: () =>
                        ref.read(connectionProvider.notifier).reconnect(),
                    child: const Text('Reconnect'),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: HoverPop(
                  child: AppPushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () =>
                        ref.read(connectionProvider.notifier).disconnect(),
                    child: const Text('Start Fresh'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final recents = ref.watch(recentReposProvider);
    final error = phase == ConnectionPhase.error ? connectionError : null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
          decoration: BoxDecoration(
            color: const Color(0xFF242426),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: MacosColors.separatorColor),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 28,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset(
                  'assets/MG_icon.png',
                  width: 100,
                  height: 100,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(height: 18),
              Text('Magic Git', style: typography.largeTitle),
              const SizedBox(height: 6),
              Text(
                'Manage your repositories anywhere',
                textAlign: TextAlign.center,
                style: typography.body.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: HoverPop(
                  child: AppPushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => _openConnectionsManager(context),
                    child: const Text('Connections Manager'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Open a configured workspace, add SSH remotes and local '
                'repositories, or clone/create a repository.',
                textAlign: TextAlign.center,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: _RecentConnectionsButton(recents: recents),
              ),
              if (error != null) ...[
                const SizedBox(height: 18),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemRedColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Styled identically to the "Add SSH Remote" button (same full-width
/// [PushButton]); tapping it drops down a small menu of recent *repositories*
/// (remote or local) that dismisses on any outside tap. Each row opens that
/// specific repo directly — no separate "pick a connection, then a repo" step.
/// Disabled when there are no recents.
class _RecentConnectionsButton extends ConsumerStatefulWidget {
  final List<RecentRepo> recents;
  const _RecentConnectionsButton({required this.recents});

  @override
  ConsumerState<_RecentConnectionsButton> createState() =>
      _RecentConnectionsButtonState();
}

class _RecentConnectionsButtonState
    extends ConsumerState<_RecentConnectionsButton> {
  final LayerLink _link = LayerLink();
  final GlobalKey _buttonKey = GlobalKey();
  OverlayEntry? _menu;
  VoidCallback? _escDisposer;

  @override
  void dispose() {
    _removeMenu();
    super.dispose();
  }

  void _removeMenu() {
    _escDisposer?.call();
    _escDisposer = null;
    _menu?.remove();
    _menu = null;
  }

  void _toggleMenu() {
    if (_menu != null) {
      _removeMenu();
      return;
    }
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 260.0;
    _menu = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Any tap outside the menu closes it.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _removeMenu,
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 6),
            child: Align(alignment: Alignment.topLeft, child: _menuCard(width)),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_menu!);
    // Escape closes the dropdown (like an outside tap), consuming the key.
    _escDisposer = EscapeDismissRegistry.register(() {
      if (_menu == null) return false;
      _removeMenu();
      return true;
    });
  }

  Future<void> _select(RecentRepo r) async {
    _removeMenu();
    switch (r) {
      case RecentRemoteRepo(:final connection, :final repoPath):
        // Open exactly this repo on its connection — connectToSaved takes an
        // explicit repoPath, so the user lands directly in the repo they
        // clicked rather than the connection's default.
        await ref
            .read(connectionProvider.notifier)
            .connectToSaved(connection, repoPath: repoPath);
      case RecentLocalRepoEntry(:final repo):
        // Mirror the switcher's saved-local open: resolve the security-scoped
        // bookmark (surfacing a dialog if the folder is gone) before connecting
        // — plus, for a linked worktree, the main repository's grant.
        final grants = await resolveSavedLocalRepo(context, repo);
        if (grants == null || !mounted) return;
        await ref
            .read(connectionProvider.notifier)
            .connectLocal(
              grants.repoPath,
              label: repo.label.isEmpty ? null : repo.label,
              id: repo.id,
              mainRepoPath: grants.mainRepoPath,
              gitDir: repo.isScoped ? repo.gitDir : null,
            );
    }
  }

  Widget _menuCard(double width) {
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: MacosColors.separatorColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in widget.recents)
              _MenuRow(
                title: r.repoName,
                subtitle: r.location,
                icon: r is RecentLocalRepoEntry
                    ? CupertinoIcons.folder
                    : CupertinoIcons.desktopcomputer,
                onTap: () => _select(r),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.recents.isEmpty;
    return CompositedTransformTarget(
      link: _link,
      child: SizedBox(
        key: _buttonKey,
        width: double.infinity,
        child: HoverPop(
          enabled: !empty,
          child: AppPushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: empty ? null : _toggleMenu,
            child: Text(
              empty ? 'No Recent Repositories' : 'Recent Repositories',
            ),
          ),
        ),
      ),
    );
  }
}

/// One selectable row in the recent-repositories drop-down: a leading transport
/// icon, the repo name, and — dimmed beneath it — where the repo lives (the
/// connection for a remote repo, the containing folder for a local one). Hover
/// tints the row.
class _MenuRow extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  const _MenuRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: _hover
            ? MacosColors.systemBlueColor.withValues(alpha: 0.25)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            MacosIcon(
              widget.icon,
              size: 16,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    widget.subtitle,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
