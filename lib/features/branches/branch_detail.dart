// Detail pane (right panel) for the Branches feature — extracted from
// branches_view.dart as a pure Phase 0 move with no behavior changes.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/branch_forge_status.dart';
import '../../core/git/branch_comparison.dart';
import '../../core/git/branch_review_query.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../common/diff_view.dart';
import '../common/inline_action_button.dart';
import '../common/split_diff_view.dart';
import '../common/tappable.dart';
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
  /// Active Review facets. The three interactive stat chips below are the
  /// chip-shaped face of three of them; the navigator's facet menu owns the
  /// rest. One state, two surfaces — they cannot disagree.
  final BranchReviewFacets facets;
  final ValueChanged<BranchReviewFacets> onFacetsChanged;

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
  /// Phase 5 lifecycle actions.
  final void Function(GitService, GitRef)? onPublish;
  final void Function(GitRef)? onCreateRequest;
  final void Function(GitRef)? onOpenHistory;
  final void Function(GitRef)? onOpenOnForge;
  /// Switches to Review / focuses comparison — used by the primary CTA and keymap.
  final VoidCallback? onCompare;

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
    required this.facets,
    required this.onFacetsChanged,
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
    this.onPublish,
    this.onCreateRequest,
    this.onOpenHistory,
    this.onOpenOnForge,
    this.onCompare,
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
    if (sel == null) return _dashboard(context, ref, vm.dashboard);
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
  /// clickable base-relative Merged/Stale/Conflicts filters. Shown when
  /// nothing is selected. Bulk cleanup is intentionally absent until Phase 4.
  Widget _dashboard(
    BuildContext context,
    WidgetRef ref,
    BranchDashboardStats s,
  ) {
    final typography = MacosTheme.of(context).typography;
    final scan = ref.watch(conflictScanControllerProvider(repoPath));
    final scanCtl = ref.read(conflictScanControllerProvider(repoPath).notifier);
    final base = baseState?.value?.base;
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
                selected: facets.stale == true,
                onTap: mode == BranchWorkspaceMode.review
                    ? () => onFacetsChanged(
                        facets.stale == true
                            ? facets.copyWith(clearStale: true)
                            : facets.copyWith(stale: true),
                      )
                    : null,
              ),
              _statChip('Pinned', s.pinned, MacosColors.systemYellowColor),
              _statChip('Remote', s.remote, MacosColors.systemGrayColor),
              _statChip('Tags', s.tags, MacosColors.systemTealColor),
              if (mode == BranchWorkspaceMode.review)
                Builder(
                  builder: (context) {
                    final r = review;
                    final mergedLabel = r == null || r.isLoading
                        ? '—'
                        : r.hasError
                        ? '!'
                        : '${r.value!.summariesByRefName.values.where((s) => s.mergedIntoBase).length}';
                    final canFilter =
                        r != null &&
                        !r.isLoading &&
                        !r.hasError &&
                        r.value != null;
                    return _reviewStatChip(
                      'Merged',
                      mergedLabel,
                      MacosColors.systemGrayColor,
                      selected: facets.mergedIntoBase == true,
                      onTap: canFilter
                          ? () => onFacetsChanged(
                              facets.mergedIntoBase == true
                                  ? facets.copyWith(clearMerged: true)
                                  : facets.copyWith(mergedIntoBase: true),
                            )
                          : null,
                    );
                  },
                ),
              if (mode == BranchWorkspaceMode.review)
                _reviewStatChip(
                  'Conflicts',
                  scan.byRefName.isEmpty && !scan.scanning
                      ? '—'
                      : '${scan.conflictRefNames.length}',
                  MacosColors.systemRedColor,
                  selected: facets.conflict,
                  onTap: scan.conflictRefNames.isEmpty
                      ? null
                      : () => onFacetsChanged(
                          facets.copyWith(conflict: !facets.conflict),
                        ),
                ),
            ],
          ),
          if (mode == BranchWorkspaceMode.review) ...[
            const SizedBox(height: 14),
            if (scan.scanning)
              Text(
                'Scanning for conflicts… ${scan.scanned}/${scan.total}',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              )
            else
              InlineActionButton(
                label: scan.byRefName.isEmpty
                    ? 'Scan for conflicts'
                    : 'Re-scan for conflicts',
                icon: CupertinoIcons.exclamationmark_shield,
                onPressed: base == null || !isFullGitOid(base.oid)
                    ? null
                    : () {
                        final branches = [
                          for (final b in vm.allLocalBranches)
                            if (!b.isHead && isFullGitOid(b.commitOid))
                              (refName: b.name, oid: b.commitOid),
                        ];
                        unawaited(
                          scanCtl.scan(baseOid: base.oid, branches: branches),
                        );
                      },
              ),
            const SizedBox(height: 6),
            Text(
              'Conflict counts stay unknown until you scan — unscanned '
              'branches are never shown as clean.',
              style: typography.caption2.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
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
    // Phase 5 primary-action precedence (§4.6).
    final remotes = ref.watch(remotesProvider(repoPath)).value ?? const <String>[];
    final unpublished = b.upstream == null;
    final canPublish = unpublished && remotes.isNotEmpty && onPublish != null;
    final hasRequest = bf != null && bf.hasRequest;
    final canCreateRequest =
        !hasRequest && onCreateRequest != null && !unpublished;

    final ({String label, IconData icon, VoidCallback? onTap}) primary;
    if (elsewhere != null) {
      primary = (
        label: 'Switch to worktree',
        icon: CupertinoIcons.square_arrow_right,
        onTap: busy ? null : () => onSwitchToWorktree(elsewhere),
      );
    } else if (!b.isHead && mode == BranchWorkspaceMode.browse) {
      primary = (
        label: 'Check out',
        icon: CupertinoIcons.square_arrow_down,
        onTap: busy ? null : () => onCheckout(git, b.shortName),
      );
    } else if (hasRequest && mode == BranchWorkspaceMode.review) {
      primary = (
        label: 'Open ${bf.requestLabel}',
        icon: CupertinoIcons.arrow_up_right_square,
        onTap: () => onOpenUrl(bf.requestUrl),
      );
    } else if (canPublish && mode == BranchWorkspaceMode.review) {
      primary = (
        label: 'Publish Branch',
        icon: CupertinoIcons.cloud_upload,
        onTap: busy ? null : () => onPublish!(git, b),
      );
    } else if (canCreateRequest && mode == BranchWorkspaceMode.review) {
      primary = (
        label: bf?.isMr == true ? 'Create Merge Request' : 'Create Pull Request',
        icon: CupertinoIcons.plus_rectangle_on_rectangle,
        onTap: busy ? null : () => onCreateRequest!(b),
      );
    } else {
      // Never a permanently disabled primary CTA — tap enters Review (or
      // reaffirms comparison) via [onCompare]; inspector stays visible below.
      primary = (
        label: 'Compare Changes',
        icon: CupertinoIcons.doc_text,
        onTap: onCompare,
      );
    }

    final secondary = <Widget>[
      if (hasRequest && primary.label != 'Open ${bf.requestLabel}')
        _detailButton(
          'Open ${bf.requestLabel}',
          CupertinoIcons.arrow_up_right_square,
          () => onOpenUrl(bf.requestUrl),
        ),
      if (bf?.ciUrl != null)
        _detailButton(
          'Open CI',
          CupertinoIcons.gauge,
          () => onOpenUrl(bf!.ciUrl),
        ),
      if (canPublish && primary.label != 'Publish Branch')
        _detailButton(
          'Publish Branch',
          CupertinoIcons.cloud_upload,
          busy ? null : () => onPublish!(git, b),
        ),
    ].take(2).toList();

    final moreItems = <MacosPulldownMenuItem>[
      if (!b.isHead && elsewhere == null)
        MacosPulldownMenuItem(
          title: const Text('Check out'),
          onTap: busy ? null : () => onCheckout(git, b.shortName),
        ),
      if (elsewhere != null)
        MacosPulldownMenuItem(
          title: const Text('Switch to worktree'),
          onTap: busy ? null : () => onSwitchToWorktree(elsewhere),
        ),
      MacosPulldownMenuItem(
        title: const Text('New worktree…'),
        onTap: busy ? null : () => onCheckoutInNewWorktree(b.shortName),
      ),
      if (canCreateRequest)
        MacosPulldownMenuItem(
          title: Text(
            bf?.isMr == true ? 'Create Merge Request' : 'Create Pull Request',
          ),
          onTap: busy ? null : () => onCreateRequest!(b),
        ),
      if (onOpenOnForge != null)
        MacosPulldownMenuItem(
          title: const Text('Open on Forge'),
          onTap: () => onOpenOnForge!(b),
        ),
      if (onOpenHistory != null)
        MacosPulldownMenuItem(
          title: const Text('Open reachable history'),
          onTap: () => onOpenHistory!(b),
        ),
      if (!b.isHead)
        MacosPulldownMenuItem(
          title: const Text('Merge into current'),
          onTap: busy ? null : () => onMerge(git, b.shortName, MergeMode.normal),
        ),
      MacosPulldownMenuItem(
        title: const Text('Set upstream…'),
        onTap: busy ? null : () => onSetUpstream(git, b),
      ),
      MacosPulldownMenuItem(
        title: const Text('Rename…'),
        onTap: busy ? null : () => onRenameBranch(git, b.shortName),
      ),
      MacosPulldownMenuItem(
        title: Text(vm.pinned.contains(b.shortName) ? 'Unpin' : 'Pin to top'),
        onTap: () => onTogglePin(b.shortName),
      ),
      if (!b.isHead && elsewhere == null)
        MacosPulldownMenuItem(
          title: const Text('Delete'),
          onTap: busy ? null : () => onDeleteBranch(git, b.shortName),
        ),
    ];

    final actions = <Widget>[
      _detailButton(primary.label, primary.icon, primary.onTap),
      ...secondary,
      MacosPulldownButton(
        title: 'More',
        items: moreItems,
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
      below: [
        _BranchComparisonInspector(
          repoPath: repoPath,
          branch: b,
          baseState: baseState,
        ),
      ],
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
      below: const [],
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

// ---------------------------------------------------------------------------
// Phase 2 — Overview / Changes / Commits comparison inspector
// ---------------------------------------------------------------------------

enum _CompareTab { overview, changes, commits }

/// Lazy three-dot comparison inspector for a local branch vs the workspace base.
///
/// Overview and Commits never watch the patch provider; Changes does once.
class _BranchComparisonInspector extends ConsumerStatefulWidget {
  final String repoPath;
  final GitRef branch;
  final AsyncValue<BranchBaseResolution>? baseState;

  const _BranchComparisonInspector({
    required this.repoPath,
    required this.branch,
    required this.baseState,
  });

  @override
  ConsumerState<_BranchComparisonInspector> createState() =>
      _BranchComparisonInspectorState();
}

class _BranchComparisonInspectorState
    extends ConsumerState<_BranchComparisonInspector> {
  _CompareTab _tab = _CompareTab.overview;
  bool _split = false;
  bool _ignoreWs = false;
  int _contextLines = 3;
  String? _anchor;

  @override
  Widget build(BuildContext context) {
    final name = widget.branch.name;
    if (_anchor != name) {
      _anchor = name;
      _tab = _CompareTab.overview;
      _split = false;
      _ignoreWs = false;
      _contextLines = 3;
    }

    final typography = MacosTheme.of(context).typography;
    final baseState = widget.baseState;
    if (baseState == null || baseState.isLoading) {
      return _section(
        typography,
        child: Text(
          'Resolving comparison base…',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      );
    }
    if (baseState.hasError) {
      return _section(
        typography,
        child: Text(
          'Could not resolve a comparison base.',
          style: typography.caption1.copyWith(color: MacosColors.systemRedColor),
        ),
      );
    }
    final base = baseState.value?.base;
    if (base == null) {
      return _section(
        typography,
        child: Text(
          'No comparison base available yet.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      );
    }
    if (!isFullGitOid(base.oid) || !isFullGitOid(widget.branch.commitOid)) {
      return _section(
        typography,
        child: Text(
          'Comparison needs full commit OIDs.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      );
    }

    final baseOid = base.oid;
    final branchOid = widget.branch.commitOid;

    return _section(
      typography,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Compared with ${base.displayName} · ${base.source.label}',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<_CompareTab>(
            groupValue: _tab,
            children: const {
              _CompareTab.overview: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('Overview'),
              ),
              _CompareTab.changes: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('Changes'),
              ),
              _CompareTab.commits: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('Commits'),
              ),
            },
            onValueChanged: (t) {
              if (t != null) setState(() => _tab = t);
            },
          ),
          const SizedBox(height: 12),
          switch (_tab) {
            _CompareTab.overview => _overview(baseOid, branchOid, base),
            _CompareTab.changes => _changes(baseOid, branchOid, base),
            _CompareTab.commits => _commits(baseOid, branchOid, base),
          },
        ],
      ),
    );
  }

  Widget _section(MacosTypography typography, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: child,
    );
  }

  Widget _overview(String baseOid, String branchOid, BranchBase base) {
    final typography = MacosTheme.of(context).typography;
    final metaAsync = ref.watch(
      branchComparisonMetadataProvider((
        repoPath: widget.repoPath,
        baseOid: baseOid,
        branchOid: branchOid,
      )),
    );
    final bf = ref
        .watch(branchForgeProvider(widget.repoPath))
        .value?[widget.branch.shortName];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _readinessCard(baseOid, branchOid, base, bf),
        const SizedBox(height: 14),
        metaAsync.when(
          loading: () => Text(
            'Loading comparison…',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          error: (e, _) => Text(
            displayError(e),
            style: typography.caption1.copyWith(
              color: MacosColors.systemRedColor,
            ),
          ),
          data: (meta) {
            if (meta.ancestry == ComparisonAncestry.unrelated) {
              return Text(
                'No common ancestor with ${base.displayName}.',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemOrangeColor,
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MacosTooltip(
                  message:
                      'Three-dot range (A...B): changes since the merge base '
                      'of A and B — what would appear in a pull request. '
                      'Distinct from two-dot (A..B), which is commits only on B.',
                  child: Text(
                    'Incoming changes from merge base '
                    '(${base.displayName}...${widget.branch.shortName}) · three-dot',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${meta.files.length} file'
                  '${meta.files.length == 1 ? '' : 's'} · '
                  '+${meta.additions} / −${meta.deletions}'
                  '${meta.truncated ? ' · truncated' : ''}',
                  style: typography.body,
                ),
                if (meta.mergeBaseOid != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Merge base ${meta.mergeBaseOid!.substring(0, 7)}',
                    style: typography.caption2.copyWith(
                      color: MacosColors.systemGrayColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                if (meta.files.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'No file changes vs base.',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  for (final f in meta.files.take(40))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '${f.status.padRight(4)} '
                        '${f.oldPath != null ? '${f.oldPath} → ${f.path}' : f.path}'
                        '${f.binary ? ' (binary)' : ''}'
                        '${f.additions != null ? '  +${f.additions}/−${f.deletions}' : ''}',
                        style: typography.caption1.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (meta.files.length > 40 || meta.truncated)
                    Text(
                      meta.truncated
                          ? 'File list truncated.'
                          : '…and ${meta.files.length - 40} more',
                      style: typography.caption2.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  /// Local merge prediction and forge request/CI as separate readiness rows.
  Widget _readinessCard(
    String baseOid,
    String branchOid,
    BranchBase base,
    BranchForge? bf,
  ) {
    final typography = MacosTheme.of(context).typography;
    final epoch = ref.watch(connectionProvider).sessionEpoch;
    final capAsync = ref.watch(
      mergePreviewCapabilityProvider((
        repoPath: widget.repoPath,
        sessionEpoch: epoch,
      )),
    );
    final previewAsync = capAsync.maybeWhen(
      data: (cap) => cap == MergePreviewCapability.supported
          ? ref.watch(
              branchMergePreviewProvider((
                repoPath: widget.repoPath,
                baseOid: baseOid,
                branchOid: branchOid,
              )),
            )
          : null,
      orElse: () => null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Readiness',
          style: typography.headline.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Local merge into ${base.displayName}',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
        const SizedBox(height: 4),
        capAsync.when(
          loading: () => Text(
            'Checking Git capability…',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          error: (e, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayError(e),
                style: typography.caption1.copyWith(
                  color: MacosColors.systemRedColor,
                ),
              ),
              const SizedBox(height: 4),
              InlineActionButton(
                label: 'Retry',
                icon: CupertinoIcons.arrow_clockwise,
                onPressed: () => ref.invalidate(
                  mergePreviewCapabilityProvider((
                    repoPath: widget.repoPath,
                    sessionEpoch: epoch,
                  )),
                ),
              ),
            ],
          ),
          data: (cap) {
            if (cap == MergePreviewCapability.unsupported) {
              return Text(
                'Requires Git 2.38+ for local merge prediction.',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemOrangeColor,
                ),
              );
            }
            final async = previewAsync;
            if (async == null) {
              return Text(
                'Checking local merge…',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              );
            }
            return async.when(
              loading: () => Text(
                'Predicting merge…',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              error: (e, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayError(e),
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemRedColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  InlineActionButton(
                    label: 'Retry',
                    icon: CupertinoIcons.arrow_clockwise,
                    onPressed: () => ref.invalidate(
                      branchMergePreviewProvider((
                        repoPath: widget.repoPath,
                        baseOid: baseOid,
                        branchOid: branchOid,
                      )),
                    ),
                  ),
                ],
              ),
              data: (preview) => _previewBody(preview, typography),
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          'Forge',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
        const SizedBox(height: 4),
        if (bf == null || !bf.hasRequest)
          Text(
            'No open request.',
            style: typography.caption1,
          )
        else ...[
          Text(
            '${bf.isMr ? 'MR' : 'PR'} ${bf.requestLabel}'
            '${bf.requestDraft ? ' (draft)' : ''}'
            '${(bf.requestTitle ?? '').isEmpty ? '' : ' — ${bf.requestTitle}'}',
            style: typography.caption1,
          ),
          if (bf.ci != null) ...[
            const SizedBox(height: 2),
            Text(
              'CI ${_ciLabel(bf.ci!)}',
              style: typography.caption1.copyWith(
                color: _forgeCiColor(bf.ci!),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _previewBody(BranchMergePreview preview, MacosTypography typography) {
    switch (preview.state) {
      case MergePreviewState.clean:
        return Text(
          'Merges cleanly into the comparison base.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGreenColor,
          ),
        );
      case MergePreviewState.unrelated:
        return Text(
          'No common ancestor — local merge prediction unavailable.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemOrangeColor,
          ),
        );
      case MergePreviewState.unsupported:
        return Text(
          'Requires Git 2.38+ for local merge prediction.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemOrangeColor,
          ),
        );
      case MergePreviewState.conflicts:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              preview.conflictPaths.isEmpty
                  ? 'Would conflict with the comparison base.'
                  : 'Would conflict in ${preview.conflictPaths.length} '
                      'path${preview.conflictPaths.length == 1 ? '' : 's'}.',
              style: typography.caption1.copyWith(
                color: MacosColors.systemRedColor,
              ),
            ),
            if (preview.conflictPaths.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final path in preview.conflictPaths.take(20))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Tappable(
                    onTap: () => setState(() => _tab = _CompareTab.changes),
                    child: Text(
                      path,
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemBlueColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (preview.conflictPaths.length > 20)
                Text(
                  '…and ${preview.conflictPaths.length - 20} more',
                  style: typography.caption2.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Tap a path to open Changes (three-dot patch).',
                style: typography.caption2.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ],
        );
    }
  }

  Widget _changes(String baseOid, String branchOid, BranchBase base) {
    final typography = MacosTheme.of(context).typography;
    final metaAsync = ref.watch(
      branchComparisonMetadataProvider((
        repoPath: widget.repoPath,
        baseOid: baseOid,
        branchOid: branchOid,
      )),
    );
    // Patch is only watched on the Changes tab, and only after ancestry is
    // known to be connected — unrelated histories must not run three-dot diff.
    final meta = metaAsync.asData?.value;
    final fetchPatch =
        meta != null && meta.ancestry == ComparisonAncestry.connected;
    final AsyncValue<String>? patchAsync = fetchPatch
        ? ref.watch(
            branchDiffProvider((
              repoPath: widget.repoPath,
              baseOid: baseOid,
              branchOid: branchOid,
              context: _contextLines,
              ignoreWhitespace: _ignoreWs,
            )),
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Incoming changes from merge base '
          '(${base.displayName}...${widget.branch.shortName}) · three-dot',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            MacosPulldownButton(
              title: _split ? 'Split' : 'Unified',
              items: [
                MacosPulldownMenuItem(
                  title: const Text('Unified'),
                  onTap: () => setState(() => _split = false),
                ),
                MacosPulldownMenuItem(
                  title: const Text('Split'),
                  onTap: () => setState(() => _split = true),
                ),
              ],
            ),
            MacosCheckbox(
              value: _ignoreWs,
              onChanged: (v) => setState(() => _ignoreWs = v),
            ),
            Text('Ignore whitespace', style: typography.caption1),
            MacosPulldownButton(
              title: 'Context $_contextLines',
              items: [
                for (final n in const [1, 3, 5, 10])
                  MacosPulldownMenuItem(
                    title: Text('$n lines'),
                    onTap: () => setState(() => _contextLines = n),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        metaAsync.when(
          loading: () => Text(
            'Loading comparison…',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          error: (e, _) => Text(
            displayError(e),
            style: typography.caption1.copyWith(
              color: MacosColors.systemRedColor,
            ),
          ),
          data: (resolved) {
            if (resolved.ancestry == ComparisonAncestry.unrelated) {
              return Text(
                'No common ancestor — three-dot patch not available.',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemOrangeColor,
                ),
              );
            }
            final async = patchAsync;
            if (async == null) {
              return Text(
                'Loading patch…',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              );
            }
            return async.when(
              loading: () => Text(
                'Loading patch…',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              error: (e, _) => Text(
                displayError(e),
                style: typography.caption1.copyWith(
                  color: MacosColors.systemRedColor,
                ),
              ),
              data: (patch) {
                if (patch.trim().isEmpty) {
                  return Text(
                    'No patch changes.',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  );
                }
                return SizedBox(
                  height: 360,
                  child: _split
                      ? SplitDiffView(diff: patch)
                      : DiffView(diff: patch),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _commits(String baseOid, String branchOid, BranchBase base) {
    final typography = MacosTheme.of(context).typography;
    final key = (
      repoPath: widget.repoPath,
      baseOid: baseOid,
      branchOid: branchOid,
    );
    final async = ref.watch(branchUniqueCommitsProvider(key));
    final notifier = ref.read(branchUniqueCommitsProvider(key).notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MacosTooltip(
          message:
              'Two-dot range (A..B): commits reachable from B but not A — '
              'unique history on this branch. Distinct from three-dot (A...B) '
              'file changes since the merge base, and from upstream to-push/to-pull.',
          child: Text(
            'Commits only on ${widget.branch.shortName} '
            '(${base.displayName}..${widget.branch.shortName}) · two-dot',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        async.when(
          loading: () => Text(
            'Loading commits…',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          error: (e, _) => Text(
            displayError(e),
            style: typography.caption1.copyWith(
              color: MacosColors.systemRedColor,
            ),
          ),
          data: (commits) {
            if (commits.isEmpty) {
              return Text(
                'No unique commits vs base.',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                            maxLines: 2,
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
                if (notifier.pageFailed) ...[
                  const SizedBox(height: 8),
                  InlineActionButton(
                    label: 'Retry',
                    icon: CupertinoIcons.arrow_clockwise,
                    onPressed: () => notifier.retryPage(),
                  ),
                ] else if (!notifier.exhausted) ...[
                  const SizedBox(height: 8),
                  InlineActionButton(
                    label: 'Show more',
                    icon: CupertinoIcons.chevron_down,
                    onPressed: () => notifier.loadMore(),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}
