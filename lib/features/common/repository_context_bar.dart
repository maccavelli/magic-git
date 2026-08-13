import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'activity_center.dart';
import 'buttons.dart';
import 'repository_context.dart';
import 'repository_workspace_models.dart';
import 'tool_icon_button.dart';

class RepositoryContextBar extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;
  final RepositoryPrimaryAction primaryAction;
  final ValueChanged<RepositoryPrimaryActionKind> onPrimaryAction;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final ValueChanged<Object>? onRevealOutput;

  const RepositoryContextBar({
    super.key,
    required this.snapshot,
    required this.primaryAction,
    required this.onPrimaryAction,
    this.onToggleSidebar,
    this.onBack,
    this.onForward,
    this.onRevealOutput,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            WorkspaceSizeClass.fromWidth(constraints.maxWidth) ==
            WorkspaceSizeClass.compact;
        return Semantics(
          container: true,
          label: 'Repository context',
          child: Container(
            height: compact ? 46 : 52,
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: MacosColors.separatorColor),
              ),
            ),
            child: Row(
              children: [
                if (compact && onToggleSidebar != null) ...[
                  ToolIconButton(
                    icon: CupertinoIcons.sidebar_left,
                    tooltip: 'Toggle sidebar',
                    onPressed: onToggleSidebar,
                  ),
                  const SizedBox(width: 2),
                ],
                ToolIconButton(
                  icon: CupertinoIcons.chevron_back,
                  tooltip: onBack == null
                      ? 'Back (no earlier location)'
                      : 'Back',
                  onPressed: onBack,
                ),
                ToolIconButton(
                  icon: CupertinoIcons.chevron_forward,
                  tooltip: onForward == null
                      ? 'Forward (no later location)'
                      : 'Forward',
                  onPressed: onForward,
                ),
                const SizedBox(width: 6),
                Expanded(child: _RepositoryIdentity(snapshot: snapshot)),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  _StatusSummary(snapshot: snapshot),
                  const SizedBox(width: 10),
                  _SupplementSummary(snapshot: snapshot),
                ] else ...[
                  const SizedBox(width: 4),
                  _CompactMetadata(snapshot: snapshot),
                ],
                const SizedBox(width: 6),
                ActivityCenterButton(repositoryPath: snapshot.repositoryPath),
                const SizedBox(width: 6),
                MacosTooltip(
                  message: primaryAction.disabledReason ?? primaryAction.label,
                  child: AppPushButton(
                    controlSize: ControlSize.regular,
                    semanticLabel: primaryAction.disabledReason == null
                        ? primaryAction.label
                        : '${primaryAction.label}, disabled: '
                              '${primaryAction.disabledReason}',
                    onPressed: primaryAction.enabled
                        ? () => onPrimaryAction(primaryAction.kind)
                        : null,
                    child: Text(primaryAction.label),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RepositoryIdentity extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  const _RepositoryIdentity({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return MacosTooltip(
      message: '${snapshot.repositoryPath}\nBranch: ${snapshot.branchLabel}',
      child: Row(
        children: [
          const MacosIcon(CupertinoIcons.folder, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              snapshot.repositoryName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.headline,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              snapshot.branchLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusSummary extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  const _StatusSummary({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      if (snapshot.conflictCount > 0) '${snapshot.conflictCount} conflicts',
      if (snapshot.conflictCount == 0 && snapshot.isDirty)
        '${snapshot.changedCount} changed',
      if (!snapshot.isDirty) 'Clean',
      if (snapshot.ahead > 0) '↑${snapshot.ahead}',
      if (snapshot.behind > 0) '↓${snapshot.behind}',
    ];
    return Semantics(
      label: labels.join(', '),
      child: ExcludeSemantics(
        child: Text(
          labels.join('  '),
          style: MacosTheme.of(context).typography.caption1,
        ),
      ),
    );
  }
}

class _SupplementSummary extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  const _SupplementSummary({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final supplement = snapshot.supplement;
    final label =
        supplement?.worktreeLabel ??
        supplement?.selectionLabel ??
        supplement?.branchLabel ??
        supplement?.revisionLabel ??
        supplement?.baseLabel ??
        supplement?.forgeLabel ??
        supplement?.recentCommitLabel ??
        snapshot.hostLabel ??
        snapshot.connectionLabel;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: MacosTheme.of(
          context,
        ).typography.caption1.copyWith(color: MacosColors.systemGrayColor),
      ),
    );
  }
}

class _CompactMetadata extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  const _CompactMetadata({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      '${snapshot.changedCount} changed, ${snapshot.conflictCount} conflicts',
      '${snapshot.ahead} ahead, ${snapshot.behind} behind',
      if (snapshot.upstreamLabel != null) 'Upstream: ${snapshot.upstreamLabel}',
      if (snapshot.connectionLabel != null) snapshot.connectionLabel!,
      if (snapshot.hostLabel != null) snapshot.hostLabel!,
      if (snapshot.supplement?.worktreeLabel != null)
        snapshot.supplement!.worktreeLabel!,
      if (snapshot.supplement?.recentCommitLabel != null)
        snapshot.supplement!.recentCommitLabel!,
      if (snapshot.supplement?.forgeLabel != null)
        snapshot.supplement!.forgeLabel!,
      if (snapshot.supplement?.branchLabel != null)
        snapshot.supplement!.branchLabel!,
      if (snapshot.supplement?.baseLabel != null)
        snapshot.supplement!.baseLabel!,
      if (snapshot.supplement?.revisionLabel != null)
        snapshot.supplement!.revisionLabel!,
      if (snapshot.supplement?.selectionLabel != null)
        snapshot.supplement!.selectionLabel!,
    ];
    return Semantics(
      button: true,
      label: 'Repository details',
      child: MacosTooltip(
        message: 'Repository details',
        child: MacosPulldownButton(
          icon: CupertinoIcons.ellipsis_circle,
          items: [
            for (final detail in details)
              MacosPulldownMenuItem(title: Text(detail), onTap: () {}),
          ],
        ),
      ),
    );
  }
}
