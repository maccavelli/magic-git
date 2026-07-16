import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/pane_layout.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/branch_switch.dart';
import '../common/escape_dismissible.dart';
import '../common/panel_shortcuts.dart';
import '../common/resizable_master_detail.dart';
import '../common/show_more_row.dart';
import '../forge/forge_widgets.dart';
import 'create_pr_sheet.dart';
import 'run_jobs_view.dart';
import 'status_color.dart';

/// GitHub overview in a left-pane / main-panel layout (mirroring the GitLab
/// panel): pull requests and workflow runs list on the left; selecting one opens
/// the relevant detail on the right — a PR's actions, or a run's jobs and logs.
/// Driven through `gh` (JSON contract) over the remote connection.
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

  // Exactly one of these is non-null: the selected left-pane item.
  int? _selectedPrNumber;
  int? _selectedRunId;

  // In-flight guards for the mutations, keyed by PR number / run id.
  final Set<int> _approvingPrs = {};
  final Set<int> _mergingPrs = {};
  final Set<int> _rerunningRuns = {};
  final Set<int> _checkingOutPrs = {};

  String get repoPath => widget.repoPath;

  @override
  void didUpdateWidget(GitHubPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      setState(() {
        _selectedPrNumber = null;
        _selectedRunId = null;
      });
      _approvingPrs.clear();
      _mergingPrs.clear();
      _rerunningRuns.clear();
      _checkingOutPrs.clear();
      _lastRuns = null;
      _runByBranch = const {};
    } else if (oldWidget.isActive && !widget.isActive) {
      // Leaving the tab — clear the selection so the run-jobs poll stream stops
      // instead of polling `gh` in the background indefinitely.
      setState(() {
        _selectedPrNumber = null;
        _selectedRunId = null;
      });
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

  void _selectPr(int number) => setState(() {
    _selectedPrNumber = number;
    _selectedRunId = null;
  });

  void _selectRun(int id) => setState(() {
    _selectedRunId = id;
    _selectedPrNumber = null;
  });

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

    final keymap = ref.watch(keymapProvider);
    final prNumber = _selectedPrNumber;
    final runId = _selectedRunId;

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
        detail: _mainPane(prs, runs),
      ),
    );
  }

  // ---- Left pane -----------------------------------------------------------

  Widget _leftPane(
    AsyncValue<List<PullRequest>> prs,
    AsyncValue<List<WorkflowRun>> runs,
    Map<String, WorkflowRun> runByBranch,
  ) {
    final fullHistory = ref.watch(workflowRunsScopeProvider(repoPath));
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ForgeSectionHeader(
          'Pull Requests',
          onRefresh: () => ref.invalidate(pullRequestsProvider(repoPath)),
          onAdd: _createPr,
          addTooltip: 'New pull request',
        ),
        asyncListSection(
          prs,
          'No open pull requests',
          (pr) => _prRow(pr, _headRunFor(pr, runByBranch)),
        ),
        const SizedBox(height: 16),
        ForgeSectionHeader(
          'Workflow Runs',
          onRefresh: () => ref.invalidate(workflowRunsProvider(repoPath)),
        ),
        // Newest 10 by default; "Show more" re-fetches the same provider with
        // the full (bounded) history — see GitLabPanel._leftPane for the
        // skipLoadingOnReload / busy-row reasoning.
        asyncListSection(
          runs,
          'No recent workflow runs',
          (r) => _runRow(r),
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
    );
  }

  Widget _prRow(PullRequest pr, WorkflowRun? headRun) {
    return ChangeRequestRow(
      badge: pr.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('#${pr.number}', MacosColors.systemBlueColor),
      title: pr.title,
      branches: '${pr.headRefName} → ${pr.baseRefName}',
      ciDotColor: headRun == null ? null : ghRunStateColor(headRun.runState),
      selected: pr.number == _selectedPrNumber,
      onTap: () => _selectPr(pr.number),
    );
  }

  Widget _runRow(WorkflowRun run) {
    return CiRunRow(
      dotColor: ghRunStateColor(run.runState),
      title: run.workflowName.isEmpty ? run.headBranch : run.workflowName,
      caption: '${run.headBranch}  ·  ${run.shortSha}',
      selected: run.id == _selectedRunId,
      onTap: () => _selectRun(run.id),
      trailing: run.isRerunnable
          ? InFlightIconButton(
              busy: _rerunningRuns.contains(run.id),
              icon: CupertinoIcons.refresh_thick,
              tooltip: 'Re-run failed jobs',
              size: 15,
              color: MacosColors.systemGreenColor,
              onPressed: () => _rerun(run.id),
            )
          : null,
    );
  }

  // ---- Main pane -----------------------------------------------------------

  Widget _mainPane(
    AsyncValue<List<PullRequest>> prs,
    AsyncValue<List<WorkflowRun>> runs,
  ) {
    if (_selectedRunId != null) {
      WorkflowRun? run;
      for (final r in runs.value ?? const <WorkflowRun>[]) {
        if (r.id == _selectedRunId) run = r;
      }
      return _runDetail(run, _selectedRunId!);
    }

    if (_selectedPrNumber != null) {
      PullRequest? pr;
      for (final p in prs.value ?? const <PullRequest>[]) {
        if (p.number == _selectedPrNumber) pr = p;
      }
      if (pr != null) return _prDetail(pr);
    }

    return const CenteredHint('Select a pull request or workflow run');
  }

  Widget _runDetail(WorkflowRun? run, int runId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CiDetailHeader(
          dotColor: ghRunStateColor(run?.runState ?? GhRunState.unknown),
          title: run == null
              ? 'Run #$runId'
              : '${run.workflowName}  ·  ${run.headBranch}',
          trailing: run != null && run.isRerunnable
              ? InFlightIconButton(
                  busy: _rerunningRuns.contains(runId),
                  icon: CupertinoIcons.refresh_thick,
                  tooltip: 'Re-run failed jobs',
                  size: 16,
                  color: MacosColors.systemGreenColor,
                  onPressed: () => _rerun(runId),
                )
              : null,
        ),
        Expanded(child: RunJobsView(repoPath: repoPath, runId: runId)),
      ],
    );
  }

  Widget _prDetail(PullRequest pr) {
    return ChangeRequestDetail(
      badge: pr.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('#${pr.number}', MacosColors.systemBlueColor),
      title: pr.title,
      lines: [
        DetailLine('Head', pr.headRefName),
        DetailLine('Base', pr.baseRefName),
        if (pr.authorLogin != null) DetailLine('Author', '@${pr.authorLogin}'),
        DetailLine('State', pr.merged ? 'merged' : pr.state),
      ],
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

  /// The "Merge" action, disabled with an explanatory tooltip when [pr] is a
  /// draft — GitHub rejects merging a draft PR, so this catches it
  /// client-side. The pulldown beside it offers the squash/rebase methods
  /// `gh pr merge` always supported but the UI never exposed.
  Widget _mergeButton(PullRequest pr) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PushButton(
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
    showMacosSheet<void>(
      context: context,
      builder: (_) =>
          EscapeDismissible(child: CreatePrSheet(repoPath: repoPath)),
    );
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
      setState(() => _selectedPrNumber = null);
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
