import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/operation_activity.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import 'activity_center.dart';
import 'buttons.dart';
import 'repository_context.dart';
import 'repository_workspace_models.dart';
import 'repository_workspace_scaffold.dart';
import 'tappable.dart';
import 'tool_icon_button.dart';
import 'workspace_appearance.dart';
import 'workspace_focus_order.dart';
import 'workspace_view_options.dart';

class RepositoryContextBar extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;
  final RepositoryPrimaryAction primaryAction;
  final ValueChanged<RepositoryPrimaryActionKind> onPrimaryAction;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final ValueChanged<OperationId>? onRevealOutput;

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
        final appearance = WorkspaceAppearanceScope.maybeOf(context);
        final preferencesScope = WorkspacePreferencesScope.maybeOf(context);
        final preferences = preferencesScope?.preferences;
        final showWorkspaceOptions =
            preferencesScope?.optionsEnabled == true &&
            preferencesScope?.onChanged != null;
        final compact =
            WorkspaceSizeClass.fromWidth(constraints.maxWidth) ==
            WorkspaceSizeClass.compact;
        return Semantics(
          container: true,
          label: 'Repository context',
          child: Container(
            height: appearance == null
                ? (compact ? 46 : 52)
                : appearance.density == WorkspaceDensity.compact
                ? (compact ? 40 : 46)
                : (compact ? 46 : 52),
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color:
                      appearance?.tokens.palette.border ??
                      MacosColors.separatorColor,
                ),
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
                if (preferences == null ||
                    preferences.visibleToolbarSlots.contains(
                      WorkspaceToolbarSlot.back,
                    ))
                  _SecondaryActionButton(
                    icon: CupertinoIcons.chevron_back,
                    label: 'Back',
                    tooltip: onBack == null
                        ? 'Back (no earlier location)'
                        : 'Back',
                    onPressed: onBack,
                    showLabel:
                        !compact && (preferences?.showToolbarLabels ?? false),
                  ),
                if (preferences == null ||
                    preferences.visibleToolbarSlots.contains(
                      WorkspaceToolbarSlot.forward,
                    ))
                  _SecondaryActionButton(
                    icon: CupertinoIcons.chevron_forward,
                    label: 'Forward',
                    tooltip: onForward == null
                        ? 'Forward (no later location)'
                        : 'Forward',
                    onPressed: onForward,
                    showLabel:
                        !compact && (preferences?.showToolbarLabels ?? false),
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
                if (showWorkspaceOptions) ...[
                  const SizedBox(width: 6),
                  const WorkspaceViewOptionsButton(),
                  const SizedBox(width: 4),
                ] else
                  const SizedBox(width: 6),
                WorkspaceFocusRegion(
                  role: WorkspacePaneRole.activity,
                  child: ActivityCenterButton(
                    repositoryPath: snapshot.repositoryPath,
                    // Forwarded so this instance is a full replacement for the
                    // second copy the Repository toolbar used to render: the
                    // reveal-in-Output affordance lived only on that copy.
                    onRevealOutput: onRevealOutput,
                  ),
                ),
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

class _SecondaryActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool showLabel;

  const _SecondaryActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    required this.showLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (!showLabel) {
      return ToolIconButton(icon: icon, tooltip: tooltip, onPressed: onPressed);
    }
    final disabled = onPressed == null;
    return MacosTooltip(
      message: tooltip,
      child: Opacity(
        opacity: disabled ? 0.35 : 1,
        child: Tappable(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MacosIcon(icon, size: 14),
                const SizedBox(width: 4),
                Text(label),
              ],
            ),
          ),
        ),
      ),
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
    // This is metadata, not commands. It used to render as a pull-down whose
    // every item had `onTap: () {}` — an affordance that looked actionable,
    // highlighted on hover, and did nothing. A tooltip says the same thing
    // honestly, and carries the full detail for VoiceOver in one utterance.
    return Semantics(
      // `container: true` because the child is now a plain icon with no
      // semantics of its own — without it this label merges into the bar's
      // node instead of being its own announceable element.
      container: true,
      label: 'Repository details',
      value: details.join(', '),
      // The tooltip's own message would otherwise merge into the label, so the
      // node would announce as "Repository details" plus the whole multi-line
      // block. The detail is carried once, as the node's value.
      child: ExcludeSemantics(
        child: MacosTooltip(
          message: details.join('\n'),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: MacosIcon(CupertinoIcons.ellipsis_circle, size: 15),
          ),
        ),
      ),
    );
  }
}
