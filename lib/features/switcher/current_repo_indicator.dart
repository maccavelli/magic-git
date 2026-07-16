import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/git_porcelain_parser.dart';

/// A passive bottom-of-sidebar indicator showing the active repository, so the
/// user can tell at a glance where they're working. Sits directly above the
/// [ConnectionSwitcher]. Renders nothing until a repo is selected; the full
/// path is available on hover (repos can share a basename across directories).
///
/// A trailing status cluster surfaces the active repo's working-tree state —
/// a dirty/conflict dot and ahead/behind counts — reusing the already-resolved
/// [statusProvider] the repo panels watch, so it costs no extra round trip.
class CurrentRepoIndicator extends ConsumerWidget {
  const CurrentRepoIndicator({super.key});

  static String _basename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repoPath = ref.watch(connectionProvider.select((c) => c.repoPath));
    if (repoPath == null || repoPath.isEmpty) return const SizedBox.shrink();

    final typography = MacosTheme.of(context).typography;
    // The active repo's status is already fetched for its panels — reuse it.
    final status = ref.watch(statusProvider(repoPath)).value;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: MacosTooltip(
        message: _tooltip(repoPath, status),
        child: Row(
          children: [
            const MacosIcon(
              CupertinoIcons.folder_fill,
              size: 15,
              color: MacosColors.systemBlueColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Repository',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                  Text(
                    _basename(repoPath),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (status != null) _statusCluster(typography, status),
          ],
        ),
      ),
    );
  }

  /// The trailing ahead/behind counts + a dirty/conflict dot. Renders nothing
  /// when the tree is clean and in sync.
  Widget _statusCluster(MacosTypography typography, GitStatus status) {
    final ahead = status.branch.ahead;
    final behind = status.branch.behind;
    final children = <Widget>[
      if (behind > 0)
        _syncCount(typography, CupertinoIcons.arrow_down, behind),
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
