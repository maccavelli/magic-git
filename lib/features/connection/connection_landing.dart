import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../common/escape_dismissible.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import '../switcher/connection_switcher.dart';
import 'connection_form.dart';
import 'local_repo_form.dart';

/// The landing (unconnected) page: a layered branding card with just two
/// actions — **Add SSH Remote** (opens the full form in a modal sheet) and
/// **Recent Workspaces** (a pull-down of the last few profiles for a one-tap
/// reconnect). Reflects connect progress/errors for the recent-connect path.
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
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: PushButton(
                  controlSize: ControlSize.large,
                  onPressed: () =>
                      ref.read(connectionProvider.notifier).reconnect(),
                  child: const Text('Reconnect'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: PushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: () =>
                      ref.read(connectionProvider.notifier).disconnect(),
                  child: const Text('Start Fresh'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final recents = ref.watch(recentWorkspacesProvider);
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
                child: PushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: () => _openConnectionsManager(context),
                  child: const Text('Connections Manager'),
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
/// [PushButton]); tapping it drops down a small menu of recent profiles that
/// dismisses on any outside tap. Disabled when there are no recents.
class _RecentConnectionsButton extends ConsumerStatefulWidget {
  final List<RecentWorkspace> recents;
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

  Future<void> _select(RecentWorkspace w) async {
    _removeMenu();
    switch (w) {
      case RecentConnection(:final connection):
        await ref.read(connectionProvider.notifier).connectToSaved(connection);
      case RecentLocalRepo(:final repo):
        // Mirror the switcher's saved-local open: resolve the security-scoped
        // bookmark (surfacing a dialog if the folder is gone) before connecting.
        final path = await resolveSavedLocalRepoPath(context, repo);
        if (path == null || !mounted) return;
        await ref
            .read(connectionProvider.notifier)
            .connectLocal(
              path,
              label: repo.label.isEmpty ? null : repo.label,
              id: repo.id,
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
            for (final w in widget.recents)
              _MenuRow(label: w.displayName, onTap: () => _select(w)),
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
        child: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: empty ? null : _toggleMenu,
          child: Text(empty ? 'No Recent Workspaces' : 'Recent Workspaces'),
        ),
      ),
    );
  }
}

/// One selectable row in the recent-connections drop-down, with a hover tint.
class _MenuRow extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _MenuRow({required this.label, required this.onTap});

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: _hover
              ? MacosColors.systemBlueColor.withValues(alpha: 0.25)
              : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Text(
            widget.label,
            style: MacosTheme.of(context).typography.body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// Hosts [ConnectionForm] in a modal sheet. The form signals success only by
/// flipping the connection state, so this listens and dismisses itself once a
/// connection is established (staying open on error so the message shows).
class NewConnectionSheet extends ConsumerWidget {
  const NewConnectionSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(connectionProvider, (_, next) {
      if (next.isConnected) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
      }
    });

    final screen = MediaQuery.sizeOf(context);
    return SizedSheet(
      width: kSheetWidth,
      height: (screen.height * 0.82).clamp(460.0, 820.0).toDouble(),
      child: SizedBox(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 10, 0),
                child: ToolIconButton(
                  icon: CupertinoIcons.xmark,
                  tooltip: 'Close',
                  size: 16,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            const Expanded(child: ConnectionForm()),
          ],
        ),
      ),
    );
  }
}
