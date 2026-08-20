import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/operation_activity.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import 'activity_center.dart';
import 'buttons.dart';
import 'link_status_chip.dart';
import 'repository_context.dart';
import 'repository_workspace_models.dart';
import 'repository_workspace_scaffold.dart';
import 'tappable.dart';
import 'tool_icon_button.dart';
import 'workspace_appearance.dart';
import 'workspace_focus_order.dart';
import 'workspace_navigation.dart';
import 'workspace_view_options.dart';

class RepositoryContextBar extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;
  final RepositoryPrimaryAction primaryAction;
  final ValueChanged<RepositoryPrimaryActionKind> onPrimaryAction;

  /// Supplied by screens that can actually sync. When present the bar renders
  /// the grouped Fetch · Pull · Push · Sync control instead of a lone button,
  /// and [primaryAction] becomes the *recommendation* — which verb to
  /// emphasize — rather than the only reachable one.
  final RepositorySyncGroup? syncGroup;

  /// Stash-everything, offered beside the sync group. It is neither a sync
  /// verb nor a navigation control, but it is the other thing you reach for
  /// constantly before syncing, so it keeps a button rather than retreating
  /// to the menu bar alone.
  final VoidCallback? onStash;

  /// Re-read the repository. Cheap, frequent, and the one control every panel
  /// wants; ⌘R and View ▸ Refresh are its other routes.
  final VoidCallback? onRefresh;

  /// Whether to show the SSH link/latency strip. The remote backend's ambient
  /// connection health had exactly one home in the app — the deleted second
  /// toolbar band — so it moves here rather than disappearing.
  final bool showLinkStatus;
  final VoidCallback? onToggleSidebar;
  final ValueChanged<OperationId>? onRevealOutput;

  const RepositoryContextBar({
    super.key,
    required this.snapshot,
    required this.primaryAction,
    required this.onPrimaryAction,
    this.syncGroup,
    this.onStash,
    this.onRefresh,
    this.showLinkStatus = false,
    this.onToggleSidebar,
    this.onRevealOutput,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final appearance = WorkspaceAppearanceScope.maybeOf(context);
        final preferencesScope = WorkspacePreferencesScope.maybeOf(context);
        final preferences = preferencesScope?.preferences;
        // A slot with no preferences to consult is shown: the bar renders in
        // places (tests, pop-outs) that carry no workspace preferences, and the
        // default there is the full bar.
        bool slotVisible(WorkspaceToolbarSlot slot) =>
            preferences == null ||
            preferences.visibleToolbarSlots.contains(slot);
        final showWorkspaceOptions =
            preferencesScope?.optionsEnabled == true &&
            preferencesScope?.onChanged != null &&
            slotVisible(WorkspaceToolbarSlot.viewOptions);
        final sizeClass = WorkspaceSizeClass.fromWidth(constraints.maxWidth);
        final compact = sizeClass == WorkspaceSizeClass.compact;
        // 0008 §3.3: collapse only at the compact size class (< 720). The
        // four verbs stay visible through the standard class, which is the
        // typical SSH content pane after a 240pt sidebar.
        final collapseSyncGroup = compact;
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
                _NavigationControls(
                  showBack: slotVisible(WorkspaceToolbarSlot.back),
                  showForward: slotVisible(WorkspaceToolbarSlot.forward),
                  showLabels:
                      !compact && (preferences?.showToolbarLabels ?? false),
                ),
                const SizedBox(width: 6),
                // The whole informational cluster shares ONE Expanded, with
                // its shrinkable pieces Flexible *inside* it. A loose Flexible
                // sibling of an Expanded would instead split the free space
                // with it — flex a loose child declines is not handed back —
                // which drags the trailing controls toward the middle.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: _RepositoryIdentity(snapshot: snapshot)),
                      if (!compact) ...[
                        if (slotVisible(
                          WorkspaceToolbarSlot.statusSummary,
                        )) ...[
                          const SizedBox(width: 10),
                          _StatusSummary(snapshot: snapshot),
                        ],
                        const SizedBox(width: 10),
                        _SupplementSummary(
                          snapshot: snapshot,
                          showConnection: slotVisible(
                            WorkspaceToolbarSlot.linkStatus,
                          ),
                        ),
                        if (showLinkStatus &&
                            slotVisible(WorkspaceToolbarSlot.linkStatus)) ...[
                          const SizedBox(width: 10),
                          const Flexible(child: SshLinkStatusRow()),
                        ],
                      ],
                    ],
                  ),
                ),
                if (compact) ...[
                  const SizedBox(width: 4),
                  _CompactMetadata(
                    snapshot: snapshot,
                    showStatus: slotVisible(WorkspaceToolbarSlot.statusSummary),
                    showConnection: slotVisible(
                      WorkspaceToolbarSlot.linkStatus,
                    ),
                  ),
                ],
                if (showWorkspaceOptions) ...[
                  const SizedBox(width: 6),
                  const WorkspaceViewOptionsButton(),
                  const SizedBox(width: 4),
                ] else
                  const SizedBox(width: 6),
                if (slotVisible(WorkspaceToolbarSlot.activity)) ...[
                  WorkspaceFocusRegion(
                    role: WorkspacePaneRole.activity,
                    child: ActivityCenterButton(
                      repositoryPath: snapshot.repositoryPath,
                      // Forwarded so this instance is a full replacement for
                      // the second copy the Repository toolbar used to render:
                      // the reveal-in-Output affordance lived only on that
                      // copy.
                      onRevealOutput: onRevealOutput,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (onStash != null &&
                    slotVisible(WorkspaceToolbarSlot.stash)) ...[
                  ToolIconButton(
                    icon: CupertinoIcons.tray_arrow_down,
                    tooltip: 'Stash changes',
                    onPressed: onStash,
                  ),
                  const SizedBox(width: 2),
                ],
                if (onRefresh != null &&
                    slotVisible(WorkspaceToolbarSlot.refresh)) ...[
                  ToolIconButton(
                    icon: CupertinoIcons.refresh,
                    tooltip: 'Refresh',
                    onPressed: onRefresh,
                  ),
                  const SizedBox(width: 4),
                ],
                // Hiding the sync group does not hide the primary action: the
                // bar falls back to the single emphasized button below, which
                // is the one control this bar always shows.
                if (syncGroup case final group?
                    when slotVisible(WorkspaceToolbarSlot.syncGroup))
                  _SyncGroup(
                    group: group,
                    recommendation: primaryAction,
                    snapshot: snapshot,
                    compact: collapseSyncGroup,
                  )
                else
                  MacosTooltip(
                    message:
                        primaryAction.disabledReason ?? primaryAction.label,
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

  /// The change-detection dot. Green when a real watcher is streaming, orange
  /// when polling covers for it, grey when nothing is watching.
  static Color _watchColor(RepositoryWatchHealth health) => switch (health) {
    RepositoryWatchHealth.live => MacosColors.systemGreenColor,
    RepositoryWatchHealth.degraded => MacosColors.systemOrangeColor,
    RepositoryWatchHealth.stopped => MacosColors.systemGrayColor,
  };

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final health = snapshot.watchHealth;
    final notice = snapshot.notice;
    return MacosTooltip(
      message: '${snapshot.repositoryPath}\nBranch: ${snapshot.branchLabel}',
      child: Row(
        children: [
          if (health != null) ...[
            MacosTooltip(
              message: snapshot.watchHint ?? '',
              child: MacosIcon(
                CupertinoIcons.circle_fill,
                size: 8,
                color: _watchColor(health),
              ),
            ),
            const SizedBox(width: 8),
          ],
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
          if (notice != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                notice,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typography.caption1.copyWith(
                  color: snapshot.noticeTone == RepositoryNoticeTone.warning
                      ? MacosColors.systemYellowColor
                      : MacosColors.systemGrayColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Back / Forward over the session's workspace history.
///
/// The state is read here rather than handed in, so every screen that renders
/// the bar gets working navigation. Five of the six used to pass nothing and so
/// showed two permanently dim chevrons, even though the history they navigate
/// is recorded on all of them.
class _NavigationControls extends ConsumerWidget {
  final bool showBack;
  final bool showForward;
  final bool showLabels;

  const _NavigationControls({
    required this.showBack,
    required this.showForward,
    required this.showLabels,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = watchWorkspaceHistory(ref);
    final back = (history?.canBack ?? false)
        ? () => restoreWorkspaceLocation(ref, forward: false)
        : null;
    final forward = (history?.canForward ?? false)
        ? () => restoreWorkspaceLocation(ref, forward: true)
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showBack)
          _SecondaryActionButton(
            icon: CupertinoIcons.chevron_back,
            label: 'Back',
            tooltip: back == null ? 'Back (no earlier location)' : 'Back',
            onPressed: back,
            showLabel: showLabels,
          ),
        if (showForward)
          _SecondaryActionButton(
            icon: CupertinoIcons.chevron_forward,
            label: 'Forward',
            tooltip: forward == null
                ? 'Forward (no later location)'
                : 'Forward',
            onPressed: forward,
            showLabel: showLabels,
          ),
      ],
    );
  }
}

class _StatusSummary extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  const _StatusSummary({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    // "Clean" is a claim about the working tree, so it is made only by a
    // screen that actually knows it — the others contribute ahead/behind and
    // nothing else, rather than reporting a zero they never measured.
    final conflicts = snapshot.conflictCount ?? 0;
    final labels = <String>[
      if (conflicts > 0) '$conflicts conflicts',
      if (conflicts == 0 && snapshot.isDirty)
        '${snapshot.changedCount} changed',
      if (snapshot.hasWorkingTreeStatus && !snapshot.isDirty) 'Clean',
      if (snapshot.ahead > 0) '↑${snapshot.ahead}',
      if (snapshot.behind > 0) '↓${snapshot.behind}',
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
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

/// What the current screen is scoped to — the worktree, selection, branch,
/// revision, base, forge or recent commit it is showing.
///
/// The tail of that chain is not screen scope but *connection* identity, so it
/// answers to the Connection status slot: with that slot off, hiding
/// [SshLinkStatusRow] while this quietly re-printed the same host was hiding
/// the control, not the information. The screen-scope labels are ungated —
/// like the repository identity block, they say what you are looking at.
class _SupplementSummary extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  /// Whether the host / connection fallback may be used. Governed by
  /// [WorkspaceToolbarSlot.linkStatus], not by the backend: a local session
  /// has no SSH strip but its connection label is still connection identity.
  final bool showConnection;

  const _SupplementSummary({
    required this.snapshot,
    required this.showConnection,
  });

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
        (showConnection
            ? snapshot.hostLabel ?? snapshot.connectionLabel
            : null);
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

/// The compact size class's disclosure for everything width pushed out of the
/// bar.
///
/// It discloses what *width* hid, never what the user did: a slot switched off
/// in View Options is switched off at every size class, so its lines are
/// omitted here too. Otherwise narrowing the window would resurrect exactly the
/// status and connection detail that hiding the slot was meant to remove.
class _CompactMetadata extends StatelessWidget {
  final RepositoryContextSnapshot snapshot;

  /// Governed by [WorkspaceToolbarSlot.statusSummary] — working-tree counts and
  /// upstream divergence.
  final bool showStatus;

  /// Governed by [WorkspaceToolbarSlot.linkStatus] — connection and host.
  final bool showConnection;

  const _CompactMetadata({
    required this.snapshot,
    required this.showStatus,
    required this.showConnection,
  });

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (showStatus && snapshot.hasWorkingTreeStatus)
        '${snapshot.changedCount} changed, ${snapshot.conflictCount ?? 0} '
            'conflicts',
      // Only meaningful against an upstream — a screen that doesn't track
      // one must stay silent, not print "0 ahead, 0 behind" (0009 M6).
      if (showStatus && snapshot.hasUpstream)
        '${snapshot.ahead} ahead, ${snapshot.behind} behind',
      if (showStatus && snapshot.upstreamLabel != null)
        'Upstream: ${snapshot.upstreamLabel}',
      if (showConnection && snapshot.connectionLabel != null)
        snapshot.connectionLabel!,
      if (showConnection && snapshot.hostLabel != null) snapshot.hostLabel!,
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
    // Nothing left to disclose — a screen with no supplement whose status and
    // connection slots are both off. Rendering the glyph anyway would leave a
    // hoverable control with an empty tooltip.
    if (details.isEmpty) return const SizedBox.shrink();
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

/// Fetch · Pull · Push · Sync as one grouped control, with the recommended
/// verb emphasized and the variants in an adjacent overflow.
///
/// The design rule this exists to enforce: **no button changes what it does.**
/// A single primary button that renames itself Fetch → Pull → Push → Sync as
/// the repository moves underneath means the control at a given pixel is a
/// different command each time you look, so nothing about it can be learned.
/// Here the ladder in `resolvePrimaryRepositoryAction` still runs — it decides
/// which of the four fixed buttons carries the ahead/behind badge as the
/// recommended next step.
///
/// Accent is a separate, weaker claim: *this verb is worth doing right now*.
/// More than one can be true at once — two commits up and three down means
/// Pull, Push and Sync are all real options — so more than one button is
/// accented. See [_isRelevant].
///
/// The variants (pull with rebase/merge, push with upstream/tags, the two
/// forces) share ONE overflow rather than getting a chevron each. Apple's
/// guidance for pull-down buttons — "If you need to list only one or two
/// items, consider using alternative components" — rules out a two-item Pull
/// menu, and two chevrons inside a four-button group reads as clutter; one
/// overflow of six is a real menu and keeps the group's shape flat.
class _SyncGroup extends StatelessWidget {
  final RepositorySyncGroup group;
  final RepositoryPrimaryAction recommendation;
  final RepositoryContextSnapshot snapshot;
  final bool compact;

  const _SyncGroup({
    required this.group,
    required this.recommendation,
    required this.snapshot,
    required this.compact,
  });

  /// The four fixed verbs, in the order they read as a sentence about the
  /// remote: bring news, take changes, give changes, do both.
  static const _verbs = <(RepositorySyncCommand, String)>[
    (RepositorySyncCommand.fetch, 'Fetch'),
    (RepositorySyncCommand.pull, 'Pull'),
    (RepositorySyncCommand.push, 'Push'),
    (RepositorySyncCommand.sync, 'Sync'),
  ];

  static const _variants = <(RepositorySyncCommand, String, bool)>[
    (RepositorySyncCommand.pullRebase, 'Pull with Rebase', false),
    (RepositorySyncCommand.pullMerge, 'Pull with Merge', false),
    (RepositorySyncCommand.pushSetUpstream, 'Push and Set Upstream', false),
    (RepositorySyncCommand.pushTags, 'Push Tags', false),
    (RepositorySyncCommand.forcePushWithLease, 'Force Push with Lease', true),
    (RepositorySyncCommand.forcePush, 'Force Push', true),
  ];

  /// Whether a verb is worth doing *right now*, from the divergence alone.
  ///
  /// Accent answers "can I usefully do this?", which is not the same question
  /// as "what should I do first?" — the ladder answers that, and only its
  /// answer carries the ahead/behind badge. Emphasising one verb and greying
  /// three equally-valid ones made Pull look unavailable while commits were
  /// waiting to come down.
  ///
  /// Fetch is relevant whenever the group is live at all: checking the remote
  /// is safe and correct at any time, and it is the ladder's own terminal
  /// answer for a clean, in-sync repository. (Whether the group is live is the
  /// caller's question — see the `recommended != null` guard at the call site.)
  bool _isRelevant(RepositorySyncCommand command) => switch (command) {
    RepositorySyncCommand.fetch => true,
    RepositorySyncCommand.pull => snapshot.behind > 0,
    RepositorySyncCommand.push => snapshot.ahead > 0,
    RepositorySyncCommand.sync => snapshot.ahead > 0 && snapshot.behind > 0,
    _ => false,
  };

  /// Which fixed verb the ladder is recommending. `publish` is a push that
  /// also sets upstream, so the emphasis belongs on Push.
  RepositorySyncCommand? get _recommended => switch (recommendation.kind) {
    RepositoryPrimaryActionKind.fetch => RepositorySyncCommand.fetch,
    RepositoryPrimaryActionKind.pull => RepositorySyncCommand.pull,
    RepositoryPrimaryActionKind.push ||
    RepositoryPrimaryActionKind.publish => RepositorySyncCommand.push,
    RepositoryPrimaryActionKind.sync => RepositorySyncCommand.sync,
    // Resolve / Continue are not sync verbs: nothing in the group is
    // emphasized while a merge or rebase is waiting on the user.
    _ => null,
  };

  /// Ahead/behind ride the emphasized verb, where the recommendation is.
  /// An in-sync branch shows nothing rather than a noisy "↑0 ↓0" — absence is
  /// the signal that there is nothing to do.
  String? get _badge {
    final ahead = snapshot.ahead;
    final behind = snapshot.behind;
    if (ahead == 0 && behind == 0) return null;
    return [if (behind > 0) '↓$behind', if (ahead > 0) '↑$ahead'].join(' ');
  }

  /// The badge in plain words, for the tooltip and for VoiceOver — arrows do
  /// not read aloud usefully.
  String get _badgeInWords {
    final ahead = snapshot.ahead;
    final upstream = snapshot.upstreamLabel;
    final plural = ahead == 1 ? '' : 's';
    return '$ahead commit$plural ahead of, ${snapshot.behind} behind'
        '${upstream == null ? '' : ' $upstream'}';
  }

  @override
  Widget build(BuildContext context) {
    final recommended = _recommended;
    // Compact: only the recommended verb keeps its button; the other three
    // join the variants in the overflow rather than wrapping onto a second
    // line or squeezing the identity out of the bar.
    final shown = compact
        ? _verbs.where((verb) => verb.$1 == recommended).toList()
        : _verbs;
    final overflowVerbs = compact
        ? _verbs.where((verb) => verb.$1 != recommended).toList()
        : const <(RepositorySyncCommand, String)>[];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (command, label) in shown) ...[
          _syncButton(
            context,
            command,
            label,
            // With a merge or rebase waiting on the user the ladder points at
            // Resolve/Continue and `recommended` is null: the group defers
            // entirely rather than accenting a Fetch that is merely *possible*
            // while the repository needs attention elsewhere.
            //
            // Otherwise the recommendation is always accented, even when
            // divergence alone would not justify it — Publish (no upstream
            // yet) is the case that would leave the whole group grey.
            accented:
                recommended != null &&
                (_isRelevant(command) || command == recommended),
            recommended: command == recommended,
          ),
          const SizedBox(width: 4),
        ],
        // Title-only (empty): macos_ui always paints its compact caret, so
        // `icon: chevron_down` stacked a second, larger arrow on top of it.
        Semantics(
          button: true,
          label: 'More sync actions',
          child: MacosPulldownButton(
            title: '',
            items: [
              for (final (command, label) in overflowVerbs)
                MacosPulldownMenuItem(
                  title: Text(label),
                  enabled: group.reasonFor(command) == null,
                  onTap: () => group.onInvoke(command),
                ),
              if (overflowVerbs.isNotEmpty) const MacosPulldownMenuDivider(),
              for (final (command, label, destructive) in _variants)
                MacosPulldownMenuItem(
                  title: Text(
                    label,
                    style: destructive
                        ? const TextStyle(color: MacosColors.systemRedColor)
                        : null,
                  ),
                  enabled: group.reasonFor(command) == null,
                  onTap: () => group.onInvoke(command),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _syncButton(
    BuildContext context,
    RepositorySyncCommand command,
    String label, {
    required bool accented,
    required bool recommended,
  }) {
    final reason = group.reasonFor(command);
    final badge = recommended ? _badge : null;
    // Both facts matter on a verb that is emphasized but cannot run: what the
    // divergence is, and why the button is dim. Neither replaces the other.
    final description = [
      badge == null ? label : _badgeInWords,
      ?reason,
    ].join(' — ');
    return MacosTooltip(
      message: description,
      child: AppPushButton(
        controlSize: ControlSize.regular,
        // Accent every verb worth doing now, not just the first one. A verb
        // that cannot run is never accented — a blue button that does nothing
        // when clicked is worse than a grey one.
        secondary: !accented || reason != null,
        semanticLabel: reason == null
            ? (badge == null ? label : '$label, $_badgeInWords')
            : '$label, disabled: $description',
        onPressed: reason == null ? () => group.onInvoke(command) : null,
        child: badge == null
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                  const SizedBox(width: 6),
                  Text(
                    badge,
                    style: MacosTheme.of(context).typography.caption1,
                  ),
                ],
              ),
      ),
    );
  }
}
