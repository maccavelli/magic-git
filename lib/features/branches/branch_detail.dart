// Detail pane (right panel) for the Branches feature — extracted from
// branches_view.dart as a pure Phase 0 move with no behavior changes.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/branch_forge_status.dart';
import '../../core/git/branch_comparison.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../common/inline_action_button.dart';
import '../common/tappable.dart';
import '../worktrees/worktree_tabs.dart';
import 'branch_dashboard_stats.dart';
import 'branch_view_model.dart';

// ---------------------------------------------------------------------------
// Tag remote-status helpers (public so branch_navigator can import from here)
// ---------------------------------------------------------------------------

/// Where a local tag stands relative to the remote's copy.
enum TagRemoteStatus {
  /// No listing available (remote unreachable, or none configured).
  unknown,

  /// The tag exists locally but not on the remote — the attention state this
  /// whole feature exists for.
  localOnly,

  /// Same name, same (unpeeled) oid — pushing again would be a no-op.
  inSync,

  /// Same name, different oid — a push would be rejected by the remote.
  differs,
}

/// Where a local tag stands relative to the remote's copy.
TagRemoteStatus tagStatus(GitRef tag, Map<String, String>? remoteTags) {
  if (remoteTags == null) return TagRemoteStatus.unknown;
  final remoteOid = remoteTags[tag.shortName];
  if (remoteOid == null) return TagRemoteStatus.localOnly;
  return remoteOid == tag.oid
      ? TagRemoteStatus.inSync
      : TagRemoteStatus.differs;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// The local branch name a remote-tracking ref [remoteShortName] (e.g.
/// `origin/feat/x`) maps to — everything after the first `/` (the remote).
String _remoteLocalName(String remoteShortName) => remoteShortName.contains('/')
    ? remoteShortName.substring(remoteShortName.indexOf('/') + 1)
    : remoteShortName;

Color _forgeCiColor(ForgeCi c) => switch (c) {
  ForgeCi.success => MacosColors.systemGreenColor,
  ForgeCi.failure => MacosColors.systemRedColor,
  ForgeCi.running => MacosColors.systemBlueColor,
  ForgeCi.canceled || ForgeCi.skipped => MacosColors.systemGrayColor,
  ForgeCi.unknown => MacosColors.systemOrangeColor,
};

String _ciLabel(ForgeCi c) => switch (c) {
  ForgeCi.success => 'passing',
  ForgeCi.failure => 'failing',
  ForgeCi.running => 'running',
  ForgeCi.canceled => 'canceled',
  ForgeCi.skipped => 'skipped',
  ForgeCi.unknown => 'unknown',
};

// ---------------------------------------------------------------------------
// BranchDetail widget
// ---------------------------------------------------------------------------

/// The right-hand detail pane of the Branches master-detail layout.
///
/// Renders contextual info and actions for the selected ref (local branch,
/// remote branch, or tag), or the empty-state dashboard when nothing is
/// selected.
class BranchDetail extends ConsumerWidget {
  final String repoPath;
  final GitService git;
  final GitRef? selectedRef;
  final BranchViewModel vm;
  final Map<String, String>? remoteTags;
  final String? tagRemote;
  final bool busy;
  final BranchWorkspaceMode mode;
  final AsyncValue<BranchBaseResolution>? baseState;
  final AsyncValue<BranchReviewBatchResult>? review;
  final BranchReviewQuickFilter reviewFilter;
  final ValueChanged<BranchReviewQuickFilter> onReviewFilterChanged;

  // Callbacks for actions the detail pane triggers
  final void Function(GitService, String) onCheckout;
  final void Function(String) onSwitchToWorktree;
  final void Function(String) onCheckoutInNewWorktree;
  final void Function(GitService, GitRef) onCheckoutRemote;
  final void Function(GitService, String, MergeMode) onMerge;
  final void Function(GitService, GitRef) onSetUpstream;
  final void Function(GitService, String) onRenameBranch;
  final void Function(String) onTogglePin;
  final void Function(GitService, String) onDeleteBranch;
  final void Function(GitService, String) onDeleteRemoteBranch;
  final void Function(GitService, GitRef, TagRemoteStatus, String?) onDeleteTag;
  final void Function(GitService, String, String) onPushTag;
  final void Function(String?) onOpenUrl;

  const BranchDetail({
    super.key,
    required this.repoPath,
    required this.git,
    required this.selectedRef,
    required this.vm,
    required this.remoteTags,
    required this.tagRemote,
    required this.busy,
    required this.mode,
    required this.baseState,
    required this.review,
    required this.reviewFilter,
    required this.onReviewFilterChanged,
    required this.onCheckout,
    required this.onSwitchToWorktree,
    required this.onCheckoutInNewWorktree,
    required this.onCheckoutRemote,
    required this.onMerge,
    required this.onSetUpstream,
    required this.onRenameBranch,
    required this.onTogglePin,
    required this.onDeleteBranch,
    required this.onDeleteRemoteBranch,
    required this.onDeleteTag,
    required this.onPushTag,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _detailPane(context, ref, selectedRef);
  }

  String _baseSummary() {
    final state = baseState;
    if (state == null || state.isLoading) return 'Resolving comparison base…';
    if (state.hasError) return 'Could not resolve a comparison base.';
    final resolution = state.value;
    final base = resolution?.base;
    if (base == null) return 'This repository has no commit to compare yet.';
    final unavailable = resolution?.unavailableStoredRef;
    final summary = 'Compared with ${base.displayName} · ${base.source.label}';
    return unavailable == null
        ? summary
        : '$summary. Saved base $unavailable is unavailable.';
  }

  // --------------------------------------------------------------------------
  // Detail pane dispatch
  // --------------------------------------------------------------------------

  Widget _detailPane(BuildContext context, WidgetRef ref, GitRef? sel) {
    if (sel == null) return _dashboard(context, vm.dashboard);
    if (sel.isTag) {
      return _tagDetail(context, sel, tagStatus(sel, remoteTags), tagRemote);
    }
    if (sel.isRemote) return _remoteDetail(context, ref, sel);
    return _localDetail(context, ref, sel);
  }

  // --------------------------------------------------------------------------
  // Dashboard (empty-state)
  // --------------------------------------------------------------------------

  /// Empty-state dashboard: at-a-glance branch counts and, in Review mode,
  /// clickable base-relative Merged/Stale filters. Shown when nothing is
  /// selected. Bulk cleanup is intentionally absent until Phase 4.
  Widget _dashboard(BuildContext context, BranchDashboardStats s) {
    final typography = MacosTheme.of(context).typography;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            mode == BranchWorkspaceMode.review ? 'Branch Review' : 'Branches',
            style: typography.title2.copyWith(fontWeight: FontWeight.w600),
          ),
          if (mode == BranchWorkspaceMode.review) ...[
            const SizedBox(height: 8),
            Text(
              _baseSummary(),
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Select a branch or tag for its details and actions — or right-'
            'click any row.',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _statChip('Local', s.local, MacosColors.systemBlueColor),
              _statChip('Active', s.active, MacosColors.systemGreenColor),
              _statChip(
                'Stale',
                s.stale,
                MacosColors.systemOrangeColor,
                selected: reviewFilter == BranchReviewQuickFilter.stale,
                onTap: mode == BranchWorkspaceMode.review
                    ? () => onReviewFilterChanged(
                        reviewFilter == BranchReviewQuickFilter.stale
                            ? BranchReviewQuickFilter.all
                            : BranchReviewQuickFilter.stale,
                      )
                    : null,
              ),
              _statChip('Pinned', s.pinned, MacosColors.systemYellowColor),
              _statChip('Remote', s.remote, MacosColors.systemGrayColor),
              _statChip('Tags', s.tags, MacosColors.systemTealColor),
              if (mode == BranchWorkspaceMode.review)
                _reviewStatChip(
                  'Merged',
                  review?.value == null
                      ? '—'
                      : '${review!.value!.summariesByRefName.values.where((s) => s.mergedIntoBase).length}',
                  MacosColors.systemGrayColor,
                  selected: reviewFilter == BranchReviewQuickFilter.merged,
                  onTap: () => onReviewFilterChanged(
                    reviewFilter == BranchReviewQuickFilter.merged
                        ? BranchReviewQuickFilter.all
                        : BranchReviewQuickFilter.merged,
                  ),
                ),
            ],
          ),
          if (s.stale > 0) ...[
            const SizedBox(height: 18),
            Text(
              '${s.stale} stale branch${s.stale == 1 ? '' : 'es'} '
              '(no commit in 3 months) — collapsed under the Local section.',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statChip(
    String label,
    int count,
    Color color, {
    bool selected = false,
    VoidCallback? onTap,
  }) =>
      _reviewStatChip(label, '$count', color, selected: selected, onTap: onTap);

  Widget _reviewStatChip(
    String label,
    String count,
    Color color, {
    bool selected = false,
    VoidCallback? onTap,
  }) {
    return Builder(
      builder: (context) {
        final typography = MacosTheme.of(context).typography;
        final chip = Container(
          width: 96,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: selected ? 0.9 : 0.25),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                count,
                style: typography.title2.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              Text(
                label,
                style: typography.caption2.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ),
        );
        return onTap == null
            ? chip
            : Tappable(
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: chip,
              );
      },
    );
  }

  // --------------------------------------------------------------------------
  // Detail scaffold
  // --------------------------------------------------------------------------

  Widget _detailScaffold({
    required IconData icon,
    required Color iconColor,
    required String name,
    required List<Widget> info,
    required List<Widget> actions,
    Widget? callout,
    List<Widget> below = const [],
  }) {
    return Builder(
      builder: (context) {
        final typography = MacosTheme.of(context).typography;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MacosIcon(icon, size: 18, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: typography.title3.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...info,
              if (callout != null) ...[const SizedBox(height: 14), callout],
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              ...below,
            ],
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // Branch commits preview
  // --------------------------------------------------------------------------

  /// The single-branch linear view: a preview of the most recent commits
  /// reachable from [revision] — GitKraken's missing "just this branch" list.
  /// Renders nothing until (and unless) [branchCommitsProvider] resolves.
  Widget _branchCommits(BuildContext context, WidgetRef ref, String revision) {
    final commits =
        ref.watch(branchCommitsProvider((repoPath, revision))).value ??
        const [];
    if (commits.isEmpty) return const SizedBox.shrink();
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text(
          'RECENT COMMITS',
          style: typography.caption2.copyWith(
            color: MacosColors.systemGrayColor,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        for (final c in commits)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(top: 5, right: 9),
                  decoration: BoxDecoration(
                    color: c.isMerge
                        ? MacosColors.systemGrayColor
                        : MacosColors.systemBlueColor,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Text(
                    c.subject,
                    style: typography.caption1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  c.shortHash,
                  style: typography.caption2.copyWith(
                    color: MacosColors.systemGrayColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  relativeIsoLabel(c.date),
                  style: typography.caption2.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Info line
  // --------------------------------------------------------------------------

  Widget _infoLine(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: typography.caption1.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Local branch detail
  // --------------------------------------------------------------------------

  Widget _localDetail(BuildContext context, WidgetRef ref, GitRef b) {
    final elsewhere = b.elsewhereWorktreePath;
    final bf = vm.forge[b.shortName];
    final reviewSummary = review?.value?.summariesByRefName[b.name];
    final isMerged = mode == BranchWorkspaceMode.review
        ? reviewSummary?.mergedIntoBase ?? false
        : !b.isHead && vm.merged.contains(b.shortName);
    final info = <Widget>[
      _infoLine(context, 'Tip commit', b.subject.isEmpty ? '—' : b.subject),
      if (b.creatorDate != null)
        _infoLine(context, 'Updated', relativeEpochLabel(b.creatorDate)),
      _infoLine(
        context,
        'Upstream',
        b.upstreamGone
            ? '${b.upstream ?? '—'} (gone)'
            : b.upstream ?? 'not tracking',
        valueColor: b.upstreamGone ? MacosColors.systemOrangeColor : null,
      ),
      if (b.ahead > 0 || b.behind > 0)
        _infoLine(
          context,
          'Upstream',
          '${b.ahead} to push · ${b.behind} to pull',
        ),
      if (mode == BranchWorkspaceMode.review && baseState?.value?.base != null)
        _infoLine(
          context,
          'Compared with',
          '${baseState!.value!.base!.displayName} '
              '(${baseState!.value!.base!.source.label})',
        ),
      if (reviewSummary != null)
        _infoLine(
          context,
          'Base divergence',
          '${reviewSummary.aheadOfBase} ahead · '
              '${reviewSummary.behindBase} behind',
        ),
      if (bf != null && bf.hasRequest)
        _infoLine(
          context,
          bf.isMr ? 'Merge request' : 'Pull request',
          '${bf.requestLabel}${bf.requestDraft ? ' (draft)' : ''}'
          '${(bf.requestTitle ?? '').isEmpty ? '' : ' — ${bf.requestTitle}'}',
        ),
      if (bf?.ci != null)
        _infoLine(
          context,
          'CI',
          _ciLabel(bf!.ci!),
          valueColor: _forgeCiColor(bf.ci!),
        ),
      if (elsewhere != null)
        _infoLine(
          context,
          'Worktree',
          elsewhere,
          valueColor: MacosColors.systemPurpleColor,
        ),
    ];
    // "Next action" hint. An open request wins; then merged/gone cleanup; then
    // the forge-free divergence hint.
    Widget? callout;
    if (isMerged) {
      final currentName = vm.allLocalBranches
          .where((r) => r.isHead)
          .map((r) => r.shortName)
          .firstOrNull;
      callout = _calloutBox(
        context,
        MacosColors.systemGrayColor,
        CupertinoIcons.checkmark_seal,
        mode == BranchWorkspaceMode.review
            ? 'Merged into ${baseState?.value?.base?.displayName ?? 'the base'}.'
            : 'Merged into current ${currentName ?? 'branch'}.',
      );
    } else if (b.upstreamGone) {
      callout = _calloutBox(
        context,
        MacosColors.systemOrangeColor,
        CupertinoIcons.exclamationmark_triangle,
        'Its upstream is gone. Confirm where its work landed before deleting.',
      );
    } else if (bf != null && bf.hasRequest) {
      callout = _calloutBox(
        context,
        MacosColors.systemBlueColor,
        CupertinoIcons.arrow_up_right_square,
        '${bf.isMr ? 'Merge' : 'Pull'} request ${bf.requestLabel} is open'
        '${bf.requestDraft ? ' (draft)' : ''}.',
      );
    } else if (!b.isHead && b.ahead > 0 && b.behind == 0) {
      callout = _calloutBox(
        context,
        MacosColors.systemGreenColor,
        CupertinoIcons.arrow_up_circle,
        '${b.ahead} commit${b.ahead == 1 ? '' : 's'} to push · none to pull'
        '${b.upstream == null ? '' : ', or open a pull request'}.',
      );
    }
    final actions = <Widget>[
      if (bf != null && bf.hasRequest)
        _detailButton(
          'Open ${bf.requestLabel}',
          CupertinoIcons.arrow_up_right_square,
          () => onOpenUrl(bf.requestUrl),
        ),
      if (!b.isHead && elsewhere == null)
        _detailButton(
          'Check out',
          CupertinoIcons.square_arrow_down,
          busy ? null : () => onCheckout(git, b.shortName),
        ),
      if (elsewhere != null)
        _detailButton(
          'Switch to worktree',
          CupertinoIcons.square_arrow_right,
          busy ? null : () => onSwitchToWorktree(elsewhere),
        ),
      _detailButton(
        'New worktree…',
        kWorktreeIcon,
        busy ? null : () => onCheckoutInNewWorktree(b.shortName),
      ),
      if (!b.isHead)
        _detailButton(
          'Merge into current',
          CupertinoIcons.arrow_merge,
          busy ? null : () => onMerge(git, b.shortName, MergeMode.normal),
        ),
      _detailButton(
        'Set upstream…',
        CupertinoIcons.arrow_up_arrow_down,
        busy ? null : () => onSetUpstream(git, b),
      ),
      _detailButton(
        'Rename…',
        CupertinoIcons.pencil,
        busy ? null : () => onRenameBranch(git, b.shortName),
      ),
      _detailButton(
        vm.pinned.contains(b.shortName) ? 'Unpin' : 'Pin to top',
        vm.pinned.contains(b.shortName)
            ? CupertinoIcons.star_slash
            : CupertinoIcons.star,
        () => onTogglePin(b.shortName),
      ),
      if (!b.isHead && elsewhere == null)
        _detailButton(
          'Delete',
          CupertinoIcons.trash,
          busy ? null : () => onDeleteBranch(git, b.shortName),
          tone: InlineActionTone.destructive,
        ),
    ];
    return _detailScaffold(
      icon: CupertinoIcons.arrow_branch,
      iconColor: b.isHead
          ? MacosColors.systemGreenColor
          : MacosColors.systemBlueColor,
      name: b.shortName,
      info: [Builder(builder: (c) => Column(children: info))],
      actions: actions,
      callout: callout,
      below: [_branchCommits(context, ref, b.shortName)],
    );
  }

  // --------------------------------------------------------------------------
  // Remote branch detail
  // --------------------------------------------------------------------------

  Widget _remoteDetail(BuildContext context, WidgetRef ref, GitRef b) {
    final localName = _remoteLocalName(b.shortName);
    return _detailScaffold(
      icon: CupertinoIcons.cloud,
      iconColor: MacosColors.systemGrayColor,
      name: b.shortName,
      info: [
        Builder(
          builder: (c) => Column(
            children: [
              _infoLine(c, 'Tip commit', b.subject.isEmpty ? '—' : b.subject),
              _infoLine(c, 'Tracking as', localName),
            ],
          ),
        ),
      ],
      actions: [
        _detailButton(
          'Check out tracking branch',
          CupertinoIcons.square_arrow_down,
          busy ? null : () => onCheckoutRemote(git, b),
        ),
        _detailButton(
          'Delete on remote',
          CupertinoIcons.trash,
          busy ? null : () => onDeleteRemoteBranch(git, b.shortName),
          tone: InlineActionTone.destructive,
        ),
      ],
      below: [_branchCommits(context, ref, b.shortName)],
    );
  }

  // --------------------------------------------------------------------------
  // Tag detail
  // --------------------------------------------------------------------------

  Widget _tagDetail(
    BuildContext context,
    GitRef tag,
    TagRemoteStatus status,
    String? remote,
  ) {
    return _detailScaffold(
      icon: CupertinoIcons.tag,
      iconColor: MacosColors.systemTealColor,
      name: tag.shortName,
      info: [
        Builder(
          builder: (c) => Column(
            children: [
              _infoLine(
                c,
                'Tip commit',
                tag.subject.isEmpty ? '—' : tag.subject,
              ),
              if (tag.creatorDate != null)
                _infoLine(c, 'Created', relativeEpochLabel(tag.creatorDate)),
              _infoLine(
                c,
                'Remote',
                switch (status) {
                  TagRemoteStatus.inSync => 'in sync with $remote',
                  TagRemoteStatus.localOnly => 'local only',
                  TagRemoteStatus.differs => 'differs from $remote',
                  TagRemoteStatus.unknown => 'unknown',
                },
                valueColor: switch (status) {
                  TagRemoteStatus.localOnly => MacosColors.systemOrangeColor,
                  TagRemoteStatus.differs => MacosColors.systemRedColor,
                  _ => null,
                },
              ),
            ],
          ),
        ),
      ],
      actions: [
        if (remote != null)
          _detailButton(
            status == TagRemoteStatus.inSync
                ? 'Already on $remote'
                : 'Push to $remote',
            CupertinoIcons.cloud_upload,
            busy || status == TagRemoteStatus.inSync
                ? null
                : () => onPushTag(git, tag.shortName, remote),
          ),
        _detailButton(
          'Delete tag',
          CupertinoIcons.trash,
          busy ? null : () => onDeleteTag(git, tag, status, remote),
          tone: InlineActionTone.destructive,
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Shared UI atoms
  // --------------------------------------------------------------------------

  Widget _detailButton(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    InlineActionTone tone = InlineActionTone.normal,
  }) => InlineActionButton(
    label: label,
    icon: icon,
    onPressed: onPressed,
    tone: tone,
  );

  Widget _calloutBox(
    BuildContext context,
    Color color,
    IconData icon,
    String text,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MacosIcon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: typography.caption1)),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Error display
  // --------------------------------------------------------------------------

  /// Renders a human-facing error message (strips raw `GitException` wrappers).
  static Widget errorWidget(BuildContext context, Object err) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      // displayError strips the raw `GitException: … (exit 128)` debug wrapper
      // to the human-facing message, matching every Forge error surface.
      displayError(err),
      style: MacosTheme.of(
        context,
      ).typography.body.copyWith(color: MacosColors.systemRedColor),
    ),
  );
}
