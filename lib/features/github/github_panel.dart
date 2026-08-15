import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/forge/merge_plan.dart';
import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/branch_switch.dart';
import '../common/buttons.dart';
import '../common/context_menu.dart';
import '../common/panel_actions.dart' show kForgePanel;
import '../common/panel_shortcuts.dart';
import '../common/prompt_form_sheet.dart';
import '../common/prompt_text_sheet.dart';
import '../common/section_collapse.dart';
import '../common/show_more_row.dart';
import '../common/workspace_focus.dart';
import '../common/workspace_navigation.dart';
import '../forge/forge_inbox.dart';
import '../forge/forge_prefs.dart';
import '../forge/forge_selection.dart';
import '../forge/forge_widgets.dart';
import '../forge/forge_workspace.dart';
import '../forge/issue_actions.dart';
import '../forge/merge_options_sheet.dart';
import '../forge/merge_readiness.dart';
import '../forge/project_sections.dart';
import 'create_pr_form.dart';
import 'run_jobs_view.dart';
import 'status_color.dart';

/// The GitHub half of the unified Forge workspace (mirroring the GitLab
/// panel): one master list (Pull Requests, Workflow Runs, Issues, Milestones,
/// Labels, Releases — collapsible, jointly filtered) beside one detail pane
/// (PR actions + checks, run jobs and logs, issue/milestone details, and the
/// inline create forms). Driven through `gh` (JSON contract) plus the
/// forge-neutral project providers.
class GitHubPanel extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether the Forge tab is currently showing this panel. Kept for parity
  /// with `GitLabPanel`: a mounted-but-invisible panel (AppShell's IndexedStack)
  /// still listens on its providers, including [runJobsProvider]'s polling
  /// stream — so leaving the tab clears the selection to let that stream stop.
  final bool isActive;

  const GitHubPanel({super.key, required this.repoPath, this.isActive = true});

  @override
  ConsumerState<GitHubPanel> createState() => _GitHubPanelState();
}

class _GitHubPanelState extends ConsumerState<GitHubPanel> {
  /// Runs shown before the "Show more" row expands the list to full history —
  /// mirrors `GitLabPanel`'s collapsed pipeline count.
  static const int _collapsedRunCount = 10;

  /// Open PRs rendered before a "Show all" row expands the section — bounds the
  /// eager row layout on a very active repo; mirrors `GitLabPanel`'s MR cap.
  static const int _collapsedPrCount = 50;

  /// Set once the user taps "Show all" on the PRs section (per panel mount).
  bool _showAllPrs = false;

  ForgeSel _sel = const ForgeNothingSel();

  /// Whether an inline create form holds unsaved content (reported via
  /// onDirtyChanged). Guards row clicks and tab-away from silently
  /// destroying a draft.
  bool _draftDirty = false;

  final _filter = TextEditingController();
  String _filterQuery = '';

  /// The Inbox's type-chip filter (session-local; the Inbox/Browse mode
  /// itself is persisted via [forgeInboxModeProvider]).
  ForgeInboxKind? _inboxType;

  /// Inbox: show only change requests with no known blocker. Session-local
  /// like [_inboxType] — a triage lens, not a saved preference.
  bool _inboxUnblockedOnly = false;

  // In-flight guards for the mutations, keyed by PR number / run id.
  final Set<int> _approvingPrs = {};
  final Set<int> _mergingPrs = {};
  final Set<int> _rerunningRuns = {};
  final Set<int> _checkingOutPrs = {};

  /// Re-entry guard shared by the secondary PR mutations (close / ready-draft /
  /// comment / request-changes / edit), keyed by PR number. These don't each
  /// need a dedicated spinner like approve/merge do; the guard just stops a
  /// second invocation (from the row menu and the detail "More" pulldown both)
  /// while one is mid-flight.
  final Set<int> _busyPrs = {};

  /// The row right-click menu (one controller for the whole panel; the entries
  /// close over whichever row was clicked). Disposed with the State.
  final ContextMenuOverlay _menu = ContextMenuOverlay();

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _menu.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GitHubPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      setState(() {
        _sel = const ForgeNothingSel();
        _draftDirty = false;
        _filter.clear();
        _filterQuery = '';
      });
      _approvingPrs.clear();
      _mergingPrs.clear();
      _rerunningRuns.clear();
      _checkingOutPrs.clear();
      _busyPrs.clear();
      _lastRuns = null;
      _runByBranch = const {};
    } else if (oldWidget.isActive && !widget.isActive) {
      // Leaving the tab — clear the selection so the run-jobs poll stream stops
      // instead of polling `gh` in the background indefinitely. EXCEPT a dirty
      // create draft, which stays mounted so tabbing away and back doesn't
      // destroy typed work.
      if (!isForgeCreateSel(_sel) || !_draftDirty) {
        setState(() => _sel = const ForgeNothingSel());
      }
    }
  }

  // Memoized branch→run fusion: recomputed only when the runs list *instance*
  // changes (Riverpod hands back the same list until invalidated).
  List<WorkflowRun>? _lastRuns;
  Map<String, WorkflowRun> _runByBranch = const {};

  Map<String, WorkflowRun> _runByBranchFor(List<WorkflowRun> runs) {
    if (identical(runs, _lastRuns)) return _runByBranch;
    _lastRuns = runs;
    final map = <String, WorkflowRun>{};
    for (final r in runs) {
      // Runs come newest-first, so the first entry per branch wins (most recent).
      if (r.headBranch.isNotEmpty) map.putIfAbsent(r.headBranch, () => r);
    }
    return _runByBranch = map;
  }

  /// The most recent workflow run for [pr]'s head branch, or null.
  WorkflowRun? _headRunFor(PullRequest pr, Map<String, WorkflowRun> byBranch) =>
      byBranch[pr.headRefName];

  /// Switches the detail pane to [next]; when that would discard a dirty
  /// inline-create draft, asks first (safe default: keep editing).
  Future<void> _select(ForgeSel next) async {
    if (isForgeCreateSel(_sel) && _draftDirty) {
      final discard = await chooseAction<bool>(
        context,
        title: 'Discard draft?',
        message: 'The item you are composing has unsaved content.',
        primaryLabel: 'Keep Editing',
        primaryValue: false,
        secondary: const [('Discard Draft', true)],
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      _sel = next;
      _draftDirty = false;
    });
    publishLandedForgeSelection(
      ref,
      repoPath: repoPath,
      forgeLabel: 'GitHub',
      selection: next,
    );
  }

  @override
  Widget build(BuildContext context) {
    // No remote at all → the gh-backed views can't work; show a friendly
    // notice rather than a raw gh error (mirrors GitLabPanel). CONFIGURED
    // remotes, not remote-tracking refs — an empty repo with a wired origin
    // must still get its forge features.
    final remotes = ref.watch(remotesProvider(repoPath)).value;
    if (remotes != null && remotes.isEmpty) {
      return const NoRemoteNotice('GitHub features');
    }
    // 0009 H3: apply a restored / palette-revealed forge object — selecting
    // by id needs no list data, the detail providers fetch on their own.
    final pendingLocation = widget.isActive
        ? pendingWorkspaceLocation(ref, kForgePanel)
        : null;
    if (pendingLocation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final location = takeWorkspaceLocation(ref, kForgePanel);
        if (location == null) return;
        final id = int.tryParse(location.identity);
        final ForgeSel? next = id == null
            ? null
            : switch (location.kind) {
                WorkspaceFocusKind.issue => ForgeIssueSel(id),
                WorkspaceFocusKind.request => ForgeChangeRequestSel(id),
                WorkspaceFocusKind.pipeline => ForgeCiRunSel(id),
                _ => null,
              };
        if (next == null) {
          markWorkspaceLocationUnavailable(ref, location);
          return;
        }
        _select(next).ignore();
      });
    }
    final prs = ref.watch(pullRequestsProvider(repoPath));
    final runs = ref.watch(workflowRunsProvider(repoPath));
    final runByBranch = _runByBranchFor(runs.value ?? const <WorkflowRun>[]);

    // A branch dropped on the Forge nav item opens the inline create form
    // seeded with that branch (see drop_registry). Consumed post-frame so the
    // build stays pure.
    final seed = ref.watch(forgeCreateSeedProvider);
    if (seed != null && seed.repoPath == repoPath) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(forgeCreateSeedProvider)?.repoPath != repoPath) return;
        ref.read(forgeCreateSeedProvider.notifier).clear();
        _select(
          ForgeCreatingChangeRequest(
            seedSource: seed.branch,
            seedBase: seed.baseRef,
          ),
        );
      });
    }

    final keymap = ref.watch(keymapProvider);
    final prNumber = switch (_sel) {
      ForgeChangeRequestSel(:final id) => id,
      _ => null,
    };
    final runId = switch (_sel) {
      ForgeCiRunSel(:final id) => id,
      _ => null,
    };

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'github.newPr': _createPr,
      'github.approve': prNumber == null ? null : () => _approve(prNumber),
      'github.merge': prNumber == null ? null : () => _merge(prNumber),
      'github.rerun': runId == null ? null : () => _rerun(runId),
      // Forge-agnostic ids: the same verb regardless of which host this repo
      // uses, so one menu item covers both panels.
      'forge.newIssue': _createIssue,
      'forge.cancelAutoMerge': prNumber == null
          ? null
          : () => _cancelAutoMerge(prNumber),
    };
    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: widget.isActive ? handlers : const {},
      child: ForgeRepositoryWorkspace(
        repoPath: repoPath,
        forgeLabel: 'GitHub',
        navigator: _leftPane(prs, runs, runByBranch),
        canvas: _mainPane(prs, runs, runByBranch),
        selection: _sel,
        primaryActionLabel: 'New Pull Request',
        onPrimaryAction: _createPr,
      ),
    );
  }

  // ---- Left pane -----------------------------------------------------------

  bool _prMatches(PullRequest pr) => forgeFilterMatch(_filterQuery, [
    pr.title,
    '#${pr.number}',
    pr.headRefName,
    pr.baseRefName,
    pr.authorLogin,
    // Labels are on the row now, so they must be filterable — issues have
    // always matched theirs.
    ...pr.labels,
  ]);

  bool _runFilterMatches(WorkflowRun r) => forgeFilterMatch(_filterQuery, [
    r.workflowName,
    r.headBranch,
    r.shortSha,
  ]);

  bool _issueMatches(ForgeIssue i) => forgeFilterMatch(_filterQuery, [
    i.title,
    i.author,
    '#${i.id}',
    ...i.labels,
  ]);

  Widget _leftPane(
    AsyncValue<List<PullRequest>> prs,
    AsyncValue<List<WorkflowRun>> runs,
    Map<String, WorkflowRun> runByBranch,
  ) {
    final fullHistory = ref.watch(workflowRunsScopeProvider(repoPath));
    final collapsed = ref.watch(collapsedSectionsProvider);
    final prsCollapsed = collapsed.contains(ForgeSections.changeRequests);
    final ciCollapsed = collapsed.contains(ForgeSections.ci);
    void toggle(String s) =>
        ref.read(collapsedSectionsProvider.notifier).toggle(s);
    final inboxMode = ref.watch(forgeInboxModeProvider);

    final prMatches = _prMatches;
    final runMatches = _runFilterMatches;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ForgeFilterField(
          controller: _filter,
          onChanged: (q) => setState(() => _filterQuery = q),
        ),
        ForgeModeSwitch(
          inbox: inboxMode,
          onChanged: (v) => ref.read(forgeInboxModeProvider.notifier).set(v),
        ),
        if (inboxMode)
          ..._inboxChildren(prs, runs, runByBranch)
        else
          // Canonical section order (Issues → Pull Requests → Labels →
          // Milestones → Releases → Workflow Runs) is composed by
          // projectSectionChildren; the two forge-specific blocks are built
          // here and slotted in.
          ...projectSectionChildren(
            ref: ref,
            repoPath: repoPath,
            forge: Forge.github,
            sel: _sel,
            onSelect: (next) => _select(next),
            filter: _filterQuery,
            collapsed: collapsed,
            onToggleCollapsed: toggle,
            onCreateIssue: _createIssue,
            onIssueContextMenu: _showIssueMenu,
            changeRequests: [
              ForgeSectionHeader(
                'Pull Requests',
                count: forgeCountLabel(prs.value?.length, null),
                collapsed: prsCollapsed,
                onToggleCollapsed: () => toggle(ForgeSections.changeRequests),
                onRefresh: () => ref.invalidate(pullRequestsProvider(repoPath)),
                onAdd: _createPr,
                addTooltip: 'New pull request',
              ),
              if (!prsCollapsed)
                asyncListSection(
                  prs,
                  _filterQuery.trim().isEmpty
                      ? 'No open pull requests'
                      : 'No matching pull requests',
                  (pr) => _prRow(pr, _headRunFor(pr, runByBranch)),
                  where: prMatches,
                  // Keep current rows up during a refresh, like the CI and
                  // Issues sections — don't blank the list to a spinner.
                  skipLoadingOnReload: true,
                  limit: _showAllPrs ? null : _collapsedPrCount,
                  overflow: (hidden) => ShowMoreRow(
                    label: 'Show $hidden more',
                    onTap: () => setState(() => _showAllPrs = true),
                  ),
                ),
            ],
            ci: [
              ForgeSectionHeader(
                'Workflow Runs',
                count: forgeCountLabel(runs.value?.length, null),
                collapsed: ciCollapsed,
                onToggleCollapsed: () => toggle(ForgeSections.ci),
                onRefresh: () => ref.invalidate(workflowRunsProvider(repoPath)),
              ),
              // Newest 10 by default; "Show more" re-fetches the same provider
              // with the full (bounded) history — see GitLabPanel._leftPane for
              // the skipLoadingOnReload / busy-row reasoning.
              if (!ciCollapsed) ...[
                asyncListSection(
                  runs,
                  _filterQuery.trim().isEmpty
                      ? 'No recent workflow runs'
                      : 'No matching workflow runs',
                  (r) => _runRow(r),
                  where: runMatches,
                  skipLoadingOnReload: true,
                  limit: fullHistory ? null : _collapsedRunCount,
                  overflow: (hidden) => ShowMoreRow(
                    label: 'Show all workflow runs',
                    onTap: () => ref
                        .read(workflowRunsScopeProvider(repoPath).notifier)
                        .expand(),
                  ),
                ),
                if (fullHistory && runs.isLoading)
                  const ShowMoreRow(label: 'Loading run history…', busy: true),
              ],
            ],
          ),
      ],
    );
  }

  /// The Inbox's triage entries: open PRs, workflow runs that need attention
  /// (failed, or still moving), and open issues — in that order, jointly
  /// filtered by the shared filter field.
  List<Widget> _inboxChildren(
    AsyncValue<List<PullRequest>> prs,
    AsyncValue<List<WorkflowRun>> runs,
    Map<String, WorkflowRun> runByBranch,
  ) {
    final issues = ref.watch(projectIssuesProvider(repoPath));
    final dashboard = ref.watch(githubProjectDashboardProvider(repoPath));
    final palette = {
      for (final l in dashboard.value?.labels ?? const <ForgeLabel>[])
        l.name: l,
    };
    // Machine status/conclusion values from the gh JSON contract: a
    // succeeded (or canceled/skipped) run isn't work, so it stays out.
    // Drive off the typed run state so this can't miss the failure aliases
    // (startup_failure/timed_out) or the live states (requested/waiting) the
    // raw strings hid — see [GhRunState.needsAttention].
    bool needsAttention(WorkflowRun r) => r.runState.needsAttention;

    final entries = <ForgeInboxEntry>[
      for (final pr in prs.value ?? const <PullRequest>[])
        if (_prMatches(pr))
          ForgeInboxEntry(
            itemKey: 'pr:${pr.number}',
            kind: ForgeInboxKind.changeRequest,
            build: (extras) => _prRow(
              pr,
              _headRunFor(pr, runByBranch),
              trailingExtras: extras,
            ),
            // The app's own canonical answer, evaluated on the list row: no
            // detail fetch, so no N+1. It cannot see conflicts or branch
            // protection, which is exactly why the chip says "No blockers"
            // rather than "Ready to merge".
            noBlockers: mergePlanForGitHub(pr: pr).canMergeNow,
          ),
      for (final r in runs.value ?? const <WorkflowRun>[])
        if (needsAttention(r) && _runFilterMatches(r))
          ForgeInboxEntry(
            itemKey: 'ci:${r.id}',
            kind: ForgeInboxKind.ci,
            build: (extras) => _runRow(r, trailingExtras: extras),
          ),
      for (final i in issues.value ?? const <ForgeIssue>[])
        if (i.id != null && _issueMatches(i))
          ForgeInboxEntry(
            itemKey: 'issue:${i.id}',
            kind: ForgeInboxKind.issue,
            build: (extras) => forgeIssueRow(
              issue: i,
              palette: palette,
              sel: _sel,
              onSelect: (next) => _select(next),
              trailing: forgeCombineTrailing(null, extras),
              onSecondaryTapUp: (d) => _showIssueMenu(d, i),
            ),
          ),
    ];
    bool settled(AsyncValue<Object?> v) => v.hasValue || v.hasError;
    return [
      ...forgeInboxChildren(
        ref: ref,
        repoPath: repoPath,
        entries: entries,
        typeFilter: _inboxType,
        onTypeFilter: (k) => setState(() => _inboxType = k),
        unblockedOnly: _inboxUnblockedOnly,
        onUnblockedOnly: (v) => setState(() => _inboxUnblockedOnly = v),
        changeRequestLabel: 'PRs',
        listsReady: settled(prs) && settled(runs) && settled(issues),
      ),
      // A failed source list must say so — an Inbox that silently omits a
      // whole category reads as "nothing needs attention".
      if (prs.hasError) SectionError(prs.error!),
      if (runs.hasError) SectionError(runs.error!),
      if (issues.hasError) SectionError(issues.error!),
    ];
  }

  Widget _prRow(
    PullRequest pr,
    WorkflowRun? headRun, {
    List<Widget> trailingExtras = const [],
  }) {
    final selected = switch (_sel) {
      ForgeChangeRequestSel(:final id) => id == pr.number,
      _ => false,
    };
    return ForgeListRow(
      // Keep the #number visible even on a draft — DRAFT rides alongside it
      // rather than replacing the number you need to cite.
      leading: pr.draft
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusBadge('#${pr.number}', MacosColors.systemBlueColor),
                const SizedBox(width: 4),
                const StatusBadge('DRAFT', MacosColors.systemGrayColor),
              ],
            )
          : StatusBadge('#${pr.number}', MacosColors.systemBlueColor),
      title: pr.title,
      titleMaxLines: 2,
      caption: pr.authorLogin != null && pr.authorLogin!.isNotEmpty
          ? '@${pr.authorLogin}  ·  ${pr.headRefName} → ${pr.baseRefName}'
          : '${pr.headRefName} → ${pr.baseRefName}',
      captionDotColor: headRun == null
          ? null
          : ghRunStateColor(headRun.runState),
      // Both signals ride the LIST response already (`gh pr list --json`
      // requests labels and reviewDecision), so these chips add no request.
      // Colors come from the PR's own label payload rather than the project
      // palette — same source GitHub renders from.
      chips: [
        ?ForgeReviewChip.forGitHub(pr.reviewDecision),
        for (var i = 0; i < pr.labels.length; i++)
          MiniLabelChip(
            pr.labels[i],
            ForgeLabel(
              name: pr.labels[i],
              color: normalizeLabelColor(
                i < pr.labelColors.length ? pr.labelColors[i] : null,
              ),
            ),
          ),
      ],
      trailing: forgeCombineTrailing(null, trailingExtras),
      selected: selected,
      onTap: () => _select(ForgeChangeRequestSel(pr.number)),
      onSecondaryTapUp: (d) =>
          _menu.show(context, d.globalPosition, _prMenu(pr), width: 240),
    );
  }

  /// The PR row's right-click menu — grouped navigate → local → collaborate →
  /// state-change, the last group ending in destructive Close. Merge variants
  /// grey out for a draft (GitHub rejects merging a draft), matching
  /// [_mergeButton]; the same actions are mirrored in the detail pane
  /// (primary trio as buttons, the rest under its "More" pulldown).
  List<ContextMenuEntry> _prMenu(PullRequest pr) {
    const draftTip =
        "Draft pull requests can't be merged — mark it ready first.";
    return [
      ContextMenuItem(
        icon: CupertinoIcons.arrow_up_right_square,
        label: 'Open in browser',
        enabled: pr.url.isNotEmpty,
        onTap: () => forgeOpenUrl(pr.url),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.link,
        label: 'Copy link',
        enabled: pr.url.isNotEmpty,
        onTap: () => forgeCopy(pr.url),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.number,
        label: 'Copy #${pr.number}',
        onTap: () => forgeCopy('#${pr.number}'),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        // square_arrow_down: the same checkout glyph the Branches tab uses.
        icon: CupertinoIcons.square_arrow_down,
        label: 'Check out branch',
        onTap: () => _checkoutPr(pr),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.text_bubble,
        label: 'Comment…',
        onTap: () => _commentPr(pr.number),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.checkmark_seal,
        label: 'Approve',
        onTap: () => _approve(pr.number),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.exclamationmark_bubble,
        label: 'Request changes…',
        onTap: () => _requestChangesPr(pr.number),
      ),
      ContextMenuItem(
        icon: pr.draft
            ? CupertinoIcons.checkmark_circle
            : CupertinoIcons.arrow_uturn_left,
        label: pr.draft ? 'Mark ready for review' : 'Convert to draft',
        onTap: () => _setPrDraft(pr.number, draft: !pr.draft),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.pencil,
        label: 'Edit…',
        onTap: () => _editPr(pr),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_merge,
        label: 'Merge',
        enabled: !pr.draft,
        disabledTooltip: draftTip,
        onTap: () => _merge(pr.number, listPr: pr),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_merge,
        label: 'Squash and merge',
        enabled: !pr.draft,
        disabledTooltip: draftTip,
        onTap: () => _merge(pr.number, method: 'squash', listPr: pr),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_merge,
        label: 'Rebase and merge',
        enabled: !pr.draft,
        disabledTooltip: draftTip,
        onTap: () => _merge(pr.number, method: 'rebase', listPr: pr),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.xmark_circle,
        label: 'Close',
        iconColor: MacosColors.systemRedColor,
        onTap: () => _closePr(pr.number),
      ),
    ];
  }

  Widget _runRow(WorkflowRun run, {List<Widget> trailingExtras = const []}) {
    final selected = switch (_sel) {
      ForgeCiRunSel(:final id) => id == run.id,
      _ => false,
    };
    final rerun = run.isRerunnable
        ? InFlightIconButton(
            busy: _rerunningRuns.contains(run.id),
            icon: CupertinoIcons.refresh_thick,
            tooltip: 'Re-run failed jobs',
            size: 15,
            color: MacosColors.systemGreenColor,
            onPressed: () => _rerun(run.id),
          )
        : null;
    return ForgeListRow(
      leading: CiDot(ghRunStateColor(run.runState)),
      title: run.workflowName.isEmpty ? run.headBranch : run.workflowName,
      caption: '${run.headBranch}  ·  ${run.shortSha}',
      selected: selected,
      onTap: () => _select(ForgeCiRunSel(run.id)),
      trailing: forgeCombineTrailing(rerun, trailingExtras),
    );
  }

  // ---- Main pane -----------------------------------------------------------

  Widget _mainPane(
    AsyncValue<List<PullRequest>> prs,
    AsyncValue<List<WorkflowRun>> runs,
    Map<String, WorkflowRun> runByBranch,
  ) {
    final remoteUrl = ref.watch(originRemoteUrlProvider(repoPath)).value;
    switch (_sel) {
      case ForgeCiRunSel(:final id):
        WorkflowRun? run;
        for (final r in runs.value ?? const <WorkflowRun>[]) {
          if (r.id == id) run = r;
        }
        return _runDetail(run, id);
      case ForgeChangeRequestSel(:final id):
        PullRequest? pr;
        for (final p in prs.value ?? const <PullRequest>[]) {
          if (p.number == id) pr = p;
        }
        if (pr != null) return _prDetail(pr, runByBranch);
        // Selected but not in the list: a failed list load should surface the
        // error, not the neutral "select something" hint (which reads as
        // "nothing is wrong") while the left-pane row still shows selected.
        if (prs.hasError) return PaneError(prs.error!);
        return const CenteredHint('Select an item on the left');
      case ForgeCreatingChangeRequest(:final seedSource, :final seedBase):
        return CreatePrForm(
          repoPath: repoPath,
          initialHead: seedSource,
          initialBase: seedBase,
          onClose: () => setState(() {
            _sel = const ForgeNothingSel();
            _draftDirty = false;
          }),
          // Land on the new PR, not the neutral pane (0009 M22).
          onCreated: (number) =>
              _select(ForgeChangeRequestSel(number)).ignore(),
          // No setState: dirtiness changes nothing visual until a row click
          // or tab-away consults it.
          onDirtyChanged: (dirty) => _draftDirty = dirty,
        );
      default:
        final project = projectDetailFor(
          ref: ref,
          repoPath: repoPath,
          forge: Forge.github,
          sel: _sel,
          remoteUrl: remoteUrl,
          onCloseCreate: () => setState(() {
            _sel = const ForgeNothingSel();
            _draftDirty = false;
          }),
          // Land on the new issue, not the neutral pane (0009 M22).
          onIssueCreated: (id) => _select(ForgeIssueSel(id)).ignore(),
          onDirtyChanged: (dirty) => _draftDirty = dirty,
        );
        if (project != null) return project;
        return const CenteredHint('Select an item on the left');
    }
  }

  Widget _runDetail(WorkflowRun? run, int runId) {
    return ForgeDetailScaffold(
      leading: CiDot(
        ghRunStateColor(run?.runState ?? GhRunState.unknown),
        size: 11,
      ),
      // Lead with the run id in both states so it's always citable (the GitLab
      // pipeline detail leads with its id too — panel parity).
      title: run == null
          ? 'Run #$runId'
          : 'Run #$runId  ·  ${run.workflowName}',
      headerActions: [
        if (run != null && run.isRerunnable)
          InFlightIconButton(
            busy: _rerunningRuns.contains(runId),
            icon: CupertinoIcons.refresh_thick,
            tooltip: 'Re-run failed jobs',
            size: 16,
            color: MacosColors.systemGreenColor,
            onPressed: () => _rerun(runId),
          ),
        OpenInBrowserButton(run?.url),
      ],
      body: RunJobsView(repoPath: repoPath, runId: runId),
    );
  }

  Widget _prDetail(PullRequest pr, Map<String, WorkflowRun> runByBranch) {
    final headRun = _headRunFor(pr, runByBranch);
    final detailAsync = ref.watch(
      pullRequestDetailProvider((repoPath, pr.number)),
    );
    final detail = detailAsync.asData?.value;
    final effective = detail ?? pr;
    final policy = ref.watch(repoMergePolicyProvider(repoPath)).asData?.value;
    final plan = mergePlanForGitHub(
      pr: effective,
      policy: policy is GhRepoMergePolicy ? policy : null,
    );
    final loading = detailAsync.isLoading && detail == null;

    final lines = <Widget>[
      DetailLine('Head', effective.headRefName),
      DetailLine('Base', effective.baseRefName),
      if (effective.authorLogin != null)
        DetailLine('Author', '@${effective.authorLogin}'),
      DetailLine('State', effective.merged ? 'merged' : effective.state),
      if (effective.reviewDecision != null &&
          effective.reviewDecision!.isNotEmpty)
        DetailLine('Review', effective.reviewDecision!),
      if (effective.mergeStateStatus != null)
        DetailLine('Merge status', effective.mergeStateStatus!),
      if (effective.headOid != null)
        DetailLine('Head SHA', effective.shortHeadOid),
      if (effective.autoMergeEnabled) const DetailLine('Auto-merge', 'enabled'),
      if (effective.labels.isNotEmpty)
        DetailLine('Labels', effective.labels.join(', ')),
      if (effective.assigneeLogins.isNotEmpty)
        DetailLine(
          'Assignees',
          effective.assigneeLogins.map((a) => '@$a').join(', '),
        ),
    ];

    return ForgeDetailScaffold(
      leading: effective.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('#${effective.number}', MacosColors.systemBlueColor),
      title: effective.title,
      headerActions: [OpenInBrowserButton(effective.url)],
      lines: lines,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: MergeReadinessStrip(
              plan: plan,
              detailLoading: loading,
              onRetry: () => ref.invalidate(
                pullRequestDetailProvider((repoPath, pr.number)),
              ),
            ),
          ),
          // The description is already in the detail payload — it was fetched
          // and dropped. Bounded like the comments band so the checks pane
          // keeps the flexible space.
          if ((effective.body ?? '').trim().isNotEmpty)
            SizedBox(
              height: 120,
              child: ForgeBodyText(effective.body!.trim()),
            ),
          Expanded(child: _prChecks(headRun)),
          ForgeCommentsSection(
            comments: ref.watch(
              changeRequestCommentsProvider((repoPath, pr.number)),
            ),
          ),
        ],
      ),
      actions: [
        InFlightPushButton(
          busy: _checkingOutPrs.contains(pr.number),
          label: 'Check out',
          secondary: true,
          onPressed: () => _checkoutPr(pr),
        ),
        InFlightPushButton(
          busy: _approvingPrs.contains(pr.number),
          label: 'Approve',
          secondary: true,
          onPressed: () => _approve(pr.number),
        ),
        if (plan.needsBranchUpdate)
          InFlightPushButton(
            busy: _busyPrs.contains(pr.number),
            label: 'Update branch',
            secondary: true,
            onPressed: () => _updatePrBranch(effective),
          ),
        // Merge affordances stay hidden until real detail exists — a
        // list-tier plan cannot vouch for mergeability (0009 H10). The
        // strip's Checking state is the only merge signal meanwhile.
        if (!loading && plan.canEnableAutoMerge)
          InFlightPushButton(
            busy: _mergingPrs.contains(pr.number),
            label: 'Enable auto-merge',
            secondary: true,
            onPressed: () => _enableAutoMerge(effective, plan),
          ),
        if (plan.autoMergeAlreadyEnabled)
          InFlightPushButton(
            busy: _mergingPrs.contains(pr.number),
            label: 'Cancel auto-merge',
            secondary: true,
            onPressed: () => _cancelAutoMerge(pr.number),
          ),
        if (_mergingPrs.contains(pr.number) &&
            !plan.canEnableAutoMerge &&
            !plan.autoMergeAlreadyEnabled)
          const ProgressCircle()
        else if (!loading && plan.canMergeNow)
          _mergeButton(effective, plan),
        _prMorePulldown(effective, detailLoading: loading),
      ],
    );
  }

  /// The detail pane's overflow for the secondary PR actions — the same set as
  /// the row's right-click menu below the primary trio, so the detail pane is a
  /// full action surface without a wall of buttons.
  Widget _prMorePulldown(PullRequest pr, {bool detailLoading = false}) {
    final plan = mergePlanForGitHub(pr: pr);
    return MacosPulldownButton(
      title: 'More',
      items: [
        MacosPulldownMenuItem(
          title: const Text('Comment…'),
          onTap: () => _commentPr(pr.number),
        ),
        MacosPulldownMenuItem(
          title: const Text('Request changes…'),
          onTap: () => _requestChangesPr(pr.number),
        ),
        // Recomputed from the row here, so it must also wait for detail
        // before offering to bypass protection (0009 H10).
        if (!detailLoading && plan.supportsAdminBypass)
          MacosPulldownMenuItem(
            title: const Text('Admin merge…'),
            onTap: () => _adminMerge(pr),
          ),
        MacosPulldownMenuItem(
          title: Text(pr.draft ? 'Mark ready for review' : 'Convert to draft'),
          onTap: () => _setPrDraft(pr.number, draft: !pr.draft),
        ),
        MacosPulldownMenuItem(
          title: const Text('Edit…'),
          onTap: () => _editPr(pr),
        ),
        MacosPulldownMenuItem(
          title: const Text('Close'),
          onTap: () => _closePr(pr.number),
        ),
      ],
    );
  }

  /// The PR detail's body: its head branch's latest workflow run (checks),
  /// inline — the selected PR and its CI live on one screen instead of two
  /// selections.
  Widget _prChecks(WorkflowRun? run) {
    if (run == null) {
      return const CenteredHint('No workflow runs for this branch');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Builder(
            builder: (context) => Text(
              'Checks  ·  ${run.workflowName.isEmpty ? 'Run' : run.workflowName} #${run.id}',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                fontWeight: FontWeight.bold,
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
        ),
        Expanded(
          child: RunJobsView(repoPath: repoPath, runId: run.id),
        ),
      ],
    );
  }

  /// The "Merge" action, disabled with an explanatory tooltip when [pr] is a
  /// draft — GitHub rejects merging a draft PR, so this catches it
  /// client-side. The pulldown beside it offers the squash/rebase methods
  /// `gh pr merge` always supported but the UI never exposed.
  Widget _mergeButton(PullRequest pr, MergePlan plan) {
    final enabled = plan.canMergeNow;
    final methods = plan.allowedMethods;
    final extras = methods.where((m) => m != MergeMethod.mergeCommit).toList();
    // Prefer plan default for the primary action label/method.
    final primaryMethod = plan.defaultMethod;
    final primaryLabel = switch (primaryMethod) {
      MergeMethod.squash => 'Squash and merge',
      MergeMethod.rebase => 'Rebase and merge',
      MergeMethod.mergeCommit => 'Merge',
    };
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppPushButton(
          controlSize: ControlSize.large,
          onPressed: enabled
              ? () => _merge(
                  pr.number,
                  method: mergeMethodFlag(primaryMethod),
                  listPr: pr,
                )
              : null,
          child: Text(primaryLabel == 'Merge' ? 'Merge' : primaryLabel),
        ),
        if (enabled && extras.isNotEmpty) ...[
          const SizedBox(width: 4),
          MacosPulldownButton(
            icon: CupertinoIcons.chevron_down,
            items: [
              for (final m in methods)
                if (m != primaryMethod)
                  MacosPulldownMenuItem(
                    title: Text(mergeMethodLabel(m)),
                    onTap: () => _merge(
                      pr.number,
                      method: mergeMethodFlag(m),
                      listPr: pr,
                    ),
                  ),
            ],
          ),
        ],
      ],
    );
    if (enabled) return row;
    final tip = plan.blockedSummary.isNotEmpty
        ? plan.blockedSummary
        : "This pull request can't be merged right now.";
    return MacosTooltip(message: tip, child: row);
  }

  // ---- Actions -------------------------------------------------------------

  void _createIssue() => _select(const ForgeCreatingIssue()).ignore();

  void _createPr() {
    _select(const ForgeCreatingChangeRequest());
  }

  /// Opens an issue row's right-click menu (shared with the GitLab panel via
  /// [showIssueContextMenu]); wired to both the Browse Issues section and the
  /// Inbox's issue rows.
  void _showIssueMenu(TapUpDetails d, ForgeIssue issue) => showIssueContextMenu(
    _menu,
    context: context,
    ref: ref,
    repoPath: repoPath,
    forge: Forge.github,
    details: d,
    issue: issue,
  );

  /// Refreshes every cache a change-request mutation can stale: the list,
  /// the open detail pane (which prefers detail over the list row), and its
  /// comments. One helper so a new mutation can't forget the detail again
  /// (0009 H11). [repoPath] is the caller's up-front capture — the active
  /// repo can change while a confirm/prompt is open.
  void _invalidateChangeRequest(String repoPath, int number) {
    ref.invalidate(pullRequestsProvider(repoPath));
    ref.invalidate(pullRequestDetailProvider((repoPath, number)));
    ref.invalidate(changeRequestCommentsProvider((repoPath, number)));
  }

  Future<void> _approve(int number) async {
    if (_approvingPrs.contains(number)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Approve pull request',
      message: 'Approve #$number on the remote GitHub repo?',
      confirmLabel: 'Approve',
    );
    if (!ok || !mounted) return;
    setState(() => _approvingPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.approvePullRequest(repoPath, number),
    );
    if (!mounted) return;
    setState(() => _approvingPrs.remove(number));
    if (success) _invalidateChangeRequest(repoPath, number);
  }

  Future<void> _adminMerge(PullRequest pr) async {
    if (_mergingPrs.contains(pr.number)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Admin merge',
      message:
          'Bypass branch protection and merge #${pr.number}? This requires '
          'admin privileges and can land unreviewed work.',
      confirmLabel: 'Admin merge',
    );
    if (!ok || !mounted) return;
    setState(() => _mergingPrs.add(pr.number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.mergePullRequest(
        repoPath,
        pr.number,
        admin: true,
        matchHeadCommit: pr.headOid,
      ),
    );
    if (!mounted) return;
    setState(() => _mergingPrs.remove(pr.number));
    if (success) {
      setState(() => _sel = const ForgeNothingSel());
      ref.invalidate(pullRequestsProvider(repoPath));
      ref.invalidate(pullRequestDetailProvider((repoPath, pr.number)));
    }
  }

  Future<void> _enableAutoMerge(PullRequest pr, MergePlan plan) async {
    if (_mergingPrs.contains(pr.number)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Enable auto-merge',
      message:
          'Enable auto-merge for #${pr.number}? It will merge when '
          'requirements are met (not immediately).',
      confirmLabel: 'Enable auto-merge',
    );
    if (!ok || !mounted) return;
    setState(() => _mergingPrs.add(pr.number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.mergePullRequest(
        repoPath,
        pr.number,
        method: mergeMethodFlag(plan.defaultMethod),
        auto: true,
        matchHeadCommit: plan.pinHeadSha ? plan.headSha : null,
      ),
    );
    if (!mounted) return;
    setState(() => _mergingPrs.remove(pr.number));
    if (success) {
      ref.invalidate(pullRequestsProvider(repoPath));
      ref.invalidate(pullRequestDetailProvider((repoPath, pr.number)));
    }
  }

  Future<void> _cancelAutoMerge(int number) async {
    if (_mergingPrs.contains(number)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Cancel auto-merge',
      message: 'Cancel auto-merge for #$number?',
      confirmLabel: 'Cancel auto-merge',
    );
    if (!ok || !mounted) return;
    setState(() => _mergingPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.mergePullRequest(repoPath, number, disableAuto: true),
    );
    if (!mounted) return;
    setState(() => _mergingPrs.remove(number));
    if (success) {
      ref.invalidate(pullRequestsProvider(repoPath));
      ref.invalidate(pullRequestDetailProvider((repoPath, number)));
    }
  }

  Future<void> _updatePrBranch(PullRequest pr) async {
    if (_busyPrs.contains(pr.number)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Update branch',
      message:
          'Update #${pr.number}\'s head branch with the latest from '
          '${pr.baseRefName}?',
      confirmLabel: 'Update branch',
    );
    if (!ok || !mounted) return;
    setState(() => _busyPrs.add(pr.number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.updatePullRequestBranch(
        repoPath,
        pr.number,
        expectedHeadSha: pr.headOid,
      ),
    );
    if (!mounted) return;
    setState(() => _busyPrs.remove(pr.number));
    if (success) {
      ref.invalidate(pullRequestDetailProvider((repoPath, pr.number)));
      ref.invalidate(pullRequestsProvider(repoPath));
    }
  }

  Future<void> _merge(
    int number, {
    String method = 'merge',
    PullRequest? listPr,
  }) async {
    if (_mergingPrs.contains(number)) return;
    final repoPath = this.repoPath;

    // Warm detail before confirm so we can pin SHA and re-check the plan.
    PullRequest detailPr =
        listPr ??
        const PullRequest(
          number: 0,
          title: '',
          state: 'open',
          merged: false,
          draft: false,
          headRefName: '',
          baseRefName: '',
          url: '',
        );
    try {
      detailPr = await ref.read(
        pullRequestDetailProvider((repoPath, number)).future,
      );
    } catch (_) {
      // Fall back to list-tier data when detail fails.
      if (listPr != null) detailPr = listPr;
    }
    if (!mounted) return;

    GhRepoMergePolicy? policy;
    final policyAsync = ref.read(repoMergePolicyProvider(repoPath));
    final policyVal = policyAsync.asData?.value;
    if (policyVal is GhRepoMergePolicy) policy = policyVal;

    final plan = mergePlanForGitHub(pr: detailPr, policy: policy);
    if (!plan.canMergeNow) {
      await showErrorDialog(
        context,
        plan.blockedSummary.isNotEmpty
            ? plan.blockedSummary
            : "This pull request can't be merged right now.",
      );
      return;
    }

    final initialMethod = switch (method) {
      'squash' => MergeMethod.squash,
      'rebase' => MergeMethod.rebase,
      _ => MergeMethod.mergeCommit,
    };
    final chosenMethod = plan.allowedMethods.contains(initialMethod)
        ? initialMethod
        : plan.defaultMethod;
    final shaNote = plan.pinHeadSha && plan.headSha != null
        ? ' (${plan.headSha!.substring(0, plan.headSha!.length.clamp(0, 7))})'
        : '';
    final options = await showMergeOptionsSheet(
      context,
      plan: plan,
      title: 'Merge pull request',
      summary: 'Merge #$number$shaNote into its base branch.',
      initialMethod: chosenMethod,
    );
    if (options == null || !mounted) return;
    setState(() => _mergingPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.mergePullRequest(
        repoPath,
        number,
        method: mergeMethodFlag(options.method),
        deleteBranch: options.deleteSource,
        matchHeadCommit: plan.pinHeadSha ? plan.headSha : null,
        subject: options.subject,
        body: options.body,
      ),
    );
    if (!mounted) return;
    setState(() => _mergingPrs.remove(number));
    if (success) {
      setState(() => _sel = const ForgeNothingSel());
      ref.invalidate(pullRequestsProvider(repoPath));
      ref.invalidate(pullRequestDetailProvider((repoPath, number)));
      if (options.deleteSource) {
        // Shared post-mutation set (refs + related) — do not hand-roll
        // individual ref invalidations (see repo_mutation_refresh_test).
        refreshAfterMutation(ref, repoPath);
      }
    }
  }

  Future<void> _closePr(int number) async {
    if (_busyPrs.contains(number)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Close pull request',
      message: 'Close #$number without merging? You can reopen it later.',
      confirmLabel: 'Close',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busyPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.closePullRequest(repoPath, number),
    );
    if (!mounted) return;
    setState(() => _busyPrs.remove(number));
    if (success) {
      // Closed → drops out of the open-PR list; clear the now-stale detail.
      setState(() => _sel = const ForgeNothingSel());
      ref.invalidate(pullRequestsProvider(repoPath));
    }
  }

  Future<void> _setPrDraft(int number, {required bool draft}) async {
    if (_busyPrs.contains(number)) return;
    final repoPath = this.repoPath;
    setState(() => _busyPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.setPullRequestDraft(repoPath, number, draft: draft),
    );
    if (!mounted) return;
    setState(() => _busyPrs.remove(number));
    if (success) _invalidateChangeRequest(repoPath, number);
  }

  Future<void> _commentPr(int number) async {
    if (_busyPrs.contains(number)) return;
    final repoPath = this.repoPath;
    final body = await promptText(
      context,
      'Comment on #$number',
      placeholder: 'Write a comment…',
      description: 'Adds a comment to the pull request on GitHub.',
      confirmLabel: 'Comment',
    );
    if (body == null || !mounted) return;
    setState(() => _busyPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.commentOnPullRequest(repoPath, number, body),
    );
    if (!mounted) return;
    setState(() => _busyPrs.remove(number));
    if (success) {
      ref.invalidate(changeRequestCommentsProvider((repoPath, number)));
    }
  }

  Future<void> _requestChangesPr(int number) async {
    if (_busyPrs.contains(number)) return;
    final repoPath = this.repoPath;
    final body = await promptText(
      context,
      'Request changes on #$number',
      placeholder: 'What needs to change?',
      description:
          'Submits a "request changes" review on GitHub (a comment is required).',
      confirmLabel: 'Request changes',
    );
    if (body == null || !mounted) return;
    setState(() => _busyPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.requestChangesOnPullRequest(repoPath, number, body),
    );
    if (!mounted) return;
    setState(() => _busyPrs.remove(number));
    if (success) _invalidateChangeRequest(repoPath, number);
  }

  /// Full title + description edit. Fetches the current fields first (the list
  /// query omits the body), then opens the shared multi-field [promptForm].
  Future<void> _editPr(PullRequest pr) async {
    if (_busyPrs.contains(pr.number)) return;
    final repoPath = this.repoPath;
    final gh = ref.read(ghServiceProvider);
    setState(() => _busyPrs.add(pr.number));
    try {
      ({String title, String body})? current;
      final fetched = await runAction(context, () async {
        current = await gh.pullRequestFields(repoPath, pr.number);
      });
      if (!fetched || current == null || !mounted) return;
      final result = await promptForm(
        context,
        'Edit pull request #${pr.number}',
        confirmLabel: 'Save',
        fields: [
          PromptField(
            key: 'title',
            label: 'Title',
            initial: current!.title,
            validate: (v) => v.isEmpty ? 'A title is required.' : null,
          ),
          PromptField(
            key: 'body',
            label: 'Description',
            initial: current!.body,
            placeholder: 'Describe the change…',
            multiline: true,
          ),
        ],
      );
      if (result == null || !mounted) return;
      final title = result['title']!;
      final body = result['body']!;
      if (title == current!.title && body == current!.body) return;
      final success = await runAction(
        context,
        () => gh.editPullRequest(repoPath, pr.number, title: title, body: body),
      );
      if (success && mounted) _invalidateChangeRequest(repoPath, pr.number);
    } finally {
      if (mounted) setState(() => _busyPrs.remove(pr.number));
    }
  }

  /// Checks out the PR's branch (`gh pr checkout`) behind the dirty-tree
  /// guardrail, then refreshes the working-tree views since HEAD has moved.
  Future<void> _checkoutPr(PullRequest pr) async {
    if (_checkingOutPrs.contains(pr.number)) return;
    final repoPath = this.repoPath;
    final gh = ref.read(ghServiceProvider);
    setState(() => _checkingOutPrs.add(pr.number));
    await guardedBranchSwitch(
      context,
      ref,
      repoPath,
      () => gh.checkoutPullRequest(repoPath, pr.number),
    );
    if (!mounted) return;
    setState(() => _checkingOutPrs.remove(pr.number));
    // Refresh even when the switch didn't complete: the guard's stash step
    // can succeed while the checkout itself fails, and the panel must show
    // that intermediate state rather than pretend nothing happened.
    refreshAfterMutation(ref, repoPath);
  }

  Future<void> _rerun(int id) async {
    if (_rerunningRuns.contains(id)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Re-run failed jobs',
      message: 'Re-run the failed jobs in run #$id?',
      confirmLabel: 'Re-run',
    );
    if (!ok || !mounted) return;
    setState(() => _rerunningRuns.add(id));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.rerunFailedJobs(repoPath, id),
    );
    if (!mounted) return;
    setState(() => _rerunningRuns.remove(id));
    if (success) {
      ref.invalidate(workflowRunsProvider(repoPath));
      ref.invalidate(runJobsProvider((repoPath, id)));
    }
  }
}
