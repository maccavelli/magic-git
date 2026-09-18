import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../common/session_location.dart';
import '../tabs/tab_ui_providers.dart';

/// The passive info card at the bottom of the sidebar, directly above the
/// Connections button: which repository ([CurrentRepoIndicator]) and where it
/// is ([CurrentLocationIndicator]), so the user can tell at a glance where
/// they're working (MADR 0052). One top border for the card, not per row.
class SessionInfoCard extends StatelessWidget {
  const SessionInfoCard({super.key});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: MacosColors.separatorColor)),
    ),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [CurrentRepoIndicator(), CurrentLocationIndicator()],
    ),
  );
}

/// One card row: a blue glyph, a grey caption over a bold single-line value,
/// an optional trailing cluster, and a tooltip. Shared so the card's rows
/// cannot drift apart in padding or type.
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String caption;
  final String value;
  final String tooltip;
  final Widget? trailing;

  const _InfoRow({
    required this.icon,
    required this.caption,
    required this.value,
    required this.tooltip,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: MacosTooltip(
        message: tooltip,
        child: Row(
          children: [
            MacosIcon(icon, size: 15, color: MacosColors.systemBlueColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    caption,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// The card's Repository row: the active repository under the one name the
/// tab title, window title and status bar also show — the tab alias when set,
/// else the directory ([repositoryDisplayNameProvider]). Renders nothing until
/// a repo is selected; the full path is on hover, so the directory stays one
/// hover away when an alias hides it.
///
/// A trailing status cluster surfaces the active repo's working-tree state —
/// a dirty/conflict dot and ahead/behind counts — reusing the already-resolved
/// [statusProvider] the repo panels watch, so it costs no extra round trip.
class CurrentRepoIndicator extends ConsumerWidget {
  const CurrentRepoIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repoPath = ref.watch(connectionProvider.select((c) => c.repoPath));
    if (repoPath == null || repoPath.isEmpty) return const SizedBox.shrink();

    final typography = MacosTheme.of(context).typography;
    // The active repo's status is already fetched for its panels — reuse it.
    final status = ref.watch(statusProvider(repoPath)).value;
    return _InfoRow(
      icon: CupertinoIcons.folder_fill,
      caption: 'Repository',
      value: ref.watch(repositoryDisplayNameProvider(repoPath)),
      tooltip: _tooltip(repoPath, status),
      trailing: status == null ? null : _statusCluster(typography, status),
    );
  }

  /// The trailing ahead/behind counts + a dirty/conflict dot. Renders nothing
  /// when the tree is clean and in sync.
  Widget _statusCluster(MacosTypography typography, GitStatus status) {
    final ahead = status.branch.ahead;
    final behind = status.branch.behind;
    final children = <Widget>[
      if (behind > 0) _syncCount(typography, CupertinoIcons.arrow_down, behind),
      if (ahead > 0) _syncCount(typography, CupertinoIcons.arrow_up, ahead),
      if (status.hasConflicts)
        _dot(MacosColors.systemRedColor)
      else if (!status.isClean)
        _dot(MacosColors.systemOrangeColor),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _syncCount(MacosTypography typography, IconData icon, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MacosIcon(icon, size: 11, color: MacosColors.systemGrayColor),
        Text(
          '$count',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      ],
    );
  }

  Widget _dot(Color color) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  String _tooltip(String repoPath, GitStatus? status) {
    if (status == null) return repoPath;
    final parts = <String>[];
    if (status.hasConflicts) {
      parts.add('${status.conflicted.length} conflicted');
    }
    final changed =
        status.staged.length + status.unstaged.length + status.untracked.length;
    if (changed > 0) parts.add('$changed uncommitted');
    if (status.branch.ahead > 0) parts.add('${status.branch.ahead} ahead');
    if (status.branch.behind > 0) parts.add('${status.branch.behind} behind');
    if (parts.isEmpty) return '$repoPath\nClean, in sync';
    return '$repoPath\n${parts.join(' · ')}';
  }
}

/// The card's Location row: where the session is. The SSH host (with
/// `user@host:port` on hover for a saved connection), or This Mac for a local
/// session — the connection itself, not the name it was given (MADR 0052).
class CurrentLocationIndicator extends ConsumerWidget {
  const CurrentLocationIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (isLocal, host, connectionId, connectionLabel) = ref.watch(
      connectionProvider.select(
        (c) => (c.isLocal, c.host, c.connectionId, c.connectionLabel),
      ),
    );
    if (isLocal) {
      return _InfoRow(
        icon: sessionLocationIcon(isLocal: true),
        caption: 'Location',
        value: 'This Mac',
        tooltip: 'On this Mac',
      );
    }
    final saved =
        ref.watch(savedConnectionsProvider).value ?? const <SavedConnection>[];
    final conn = connectionId == null
        ? null
        : saved.where((c) => c.id == connectionId).firstOrNull;
    final value = host ?? connectionLabel ?? 'Connected';
    return _InfoRow(
      icon: sessionLocationIcon(isLocal: false),
      caption: 'Location',
      value: value,
      tooltip: conn == null
          ? value
          : '${conn.username}@${conn.host}:${conn.port}',
    );
  }
}
