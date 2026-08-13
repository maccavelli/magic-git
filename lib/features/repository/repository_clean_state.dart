import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../common/repository_context.dart';

class RepositoryCleanState extends StatelessWidget {
  final String branchLabel;
  final RepositoryContextSupplement? supplement;

  const RepositoryCleanState({
    super.key,
    required this.branchLabel,
    this.supplement,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final enrichment = supplement?.recentCommitLabel ?? supplement?.forgeLabel;
    return Semantics(
      container: true,
      label: 'Working tree clean on $branchLabel',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MacosIcon(
                CupertinoIcons.check_mark_circled,
                size: 34,
                color: MacosColors.systemGreenColor,
              ),
              const SizedBox(height: 10),
              Text('Working tree clean', style: typography.headline),
              const SizedBox(height: 4),
              Text(
                branchLabel,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              if (enrichment != null && enrichment.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  enrichment,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: typography.caption1,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
