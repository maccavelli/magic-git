import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/pane_layout.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/branch_switch.dart';
import '../common/buttons.dart';
import '../common/panel_shortcuts.dart';
import '../common/resizable_master_detail.dart';
import '../common/show_more_row.dart';
import '../forge/forge_inbox.dart';
import '../forge/forge_prefs.dart';
import '../forge/forge_selection.dart';
import '../forge/forge_widgets.dart';
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

  // In-flight guards for the mutations, keyed by PR number / run id.
  final Set<int> _approvingPrs = {};
  final Set<int> _mergingPrs = {};
  final Set<int> _rerunningRuns = {};
  final Set<int> _checkingOutPrs = {};

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
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
        _select(ForgeCreatingChangeRequest(seedSource: seed.branch));
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
    };
    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: widget.isActive ? handlers : const {},
      child: ResizableMasterDetail(
        paneId: PaneId.forgeList,
        master: _leftPane(prs, runs, runByBranch),
        detail: _mainPane(prs, runs, runByBranch),
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
    final collapsed = ref.watch(forgeCollapsedSectionsProvider);
    final prsCollapsed = collapsed.contains(ForgeSections.changeRequests);
    final ciCollapsed = collapsed.contains(ForgeSections.ci);
    void toggle(String s) =>
        ref.read(forgeCollapsedSectionsProvider.notifier).toggle(s);
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
        else ...[
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
            ),
          const SizedBox(height: 16),
          ForgeSectionHeader(
            'Workflow Runs',
            count: forgeCountLabel(runs.value?.length, null),
            collapsed: ciCollapsed,
            onToggleCollapsed: () => toggle(ForgeSections.ci),
            onRefresh: () => ref.invalidate(workflowRunsProvider(repoPath)),
          ),
          // Newest 10 by default; "Show more" re-fetches the same provider with
          // the full (bounded) history — see GitLabPanel._leftPane for the
          // skipLoadingOnReload / busy-row reasoning.
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
          const SizedBox(height: 16),
          ...projectSectionChildren(
            ref: ref,
            repoPath: repoPath,
            forge: Forge.github,
            sel: _sel,
            onSelect: (next) => _select(next),
            filter: _filterQuery,
            collapsed: collapsed,
            onToggleCollapsed: toggle,
            onCreateIssue: () => _select(const ForgeCreatingIssue()),
          ),
        ],
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
    bool needsAttention(WorkflowRun r) =>
        r.conclusion == 'failure' ||
        const {'queued', 'in_progress'}.contains(r.status);

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
      leading: pr.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('#${pr.number}', MacosColors.systemBlueColor),
      title: pr.title,
      titleMaxLines: 2,
      caption: '${pr.headRefName} → ${pr.baseRefName}',
      captionDotColor: headRun == null
          ? null
          : ghRunStateColor(headRun.runState),
      trailing: forgeCombineTrailing(null, trailingExtras),
      selected: selected,
      onTap: () => _select(ForgeChangeRequestSel(pr.number)),
    );
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
      case ForgeCreatingChangeRequest(:final seedSource):
        return CreatePrForm(
          repoPath: repoPath,
          initialHead: seedSource,
          onClose: () => setState(() {
            _sel = const ForgeNothingSel();
            _draftDirty = false;
          }),
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
      title: run == null
          ? 'Run #$runId'
          : '${run.workflowName}  ·  ${run.headBranch}',
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
    return ForgeDetailScaffold(
      leading: pr.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('#${pr.number}', MacosColors.systemBlueColor),
      title: pr.title,
      headerActions: [OpenInBrowserButton(pr.url)],
      lines: [
        DetailLine('Head', pr.headRefName),
        DetailLine('Base', pr.baseRefName),
        if (pr.authorLogin != null) DetailLine('Author', '@${pr.authorLogin}'),
        DetailLine('State', pr.merged ? 'merged' : pr.state),
      ],
      body: _prChecks(headRun),
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
        if (_mergingPrs.contains(pr.number))
          const ProgressCircle()
        else
          _mergeButton(pr),
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
  Widget _mergeButton(PullRequest pr) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppPushButton(
          controlSize: ControlSize.large,
          onPressed: pr.draft ? null : () => _merge(pr.number),
          child: const Text('Merge'),
        ),
        if (!pr.draft) ...[
          const SizedBox(width: 4),
          MacosPulldownButton(
            icon: CupertinoIcons.chevron_down,
            items: [
              MacosPulldownMenuItem(
                title: const Text('Squash and merge'),
                onTap: () => _merge(pr.number, method: 'squash'),
              ),
              MacosPulldownMenuItem(
                title: const Text('Rebase and merge'),
                onTap: () => _merge(pr.number, method: 'rebase'),
              ),
            ],
          ),
        ],
      ],
    );
    if (!pr.draft) return row;
    return MacosTooltip(
      message: "Draft pull requests can't be merged — mark it ready first.",
      child: row,
    );
  }

  // ---- Actions -------------------------------------------------------------

  void _createPr() {
    _select(const ForgeCreatingChangeRequest());
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
    if (success) {
      ref.invalidate(pullRequestsProvider(repoPath));
    }
  }

  Future<void> _merge(int number, {String method = 'merge'}) async {
    if (_mergingPrs.contains(number)) return;
    final repoPath = this.repoPath;
    final verb = switch (method) {
      'squash' => 'Squash-merge',
      'rebase' => 'Rebase-merge',
      _ => 'Merge',
    };
    final ok = await confirmAction(
      context,
      title: 'Merge pull request',
      message: '$verb #$number into its base branch?',
      confirmLabel: verb,
    );
    if (!ok || !mounted) return;
    setState(() => _mergingPrs.add(number));
    final gh = ref.read(ghServiceProvider);
    final success = await runAction(
      context,
      () => gh.mergePullRequest(repoPath, number, method: method),
    );
    if (!mounted) return;
    setState(() => _mergingPrs.remove(number));
    if (success) {
      setState(() => _sel = const ForgeNothingSel());
      ref.invalidate(pullRequestsProvider(repoPath));
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
