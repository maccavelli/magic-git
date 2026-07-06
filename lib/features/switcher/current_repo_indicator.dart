import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';

/// A passive bottom-of-sidebar indicator showing the active repository, so the
/// user can tell at a glance where they're working. Sits directly above the
/// [ConnectionSwitcher]. Renders nothing until a repo is selected; the full
/// path is available on hover (repos can share a basename across directories).
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
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: MacosTooltip(
        message: repoPath,
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
          ],
        ),
      ),
    );
  }
}
