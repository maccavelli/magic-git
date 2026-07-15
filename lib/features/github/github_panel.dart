import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/branch_switch.dart';
import '../common/escape_dismissible.dart';
import '../common/panel_shortcuts.dart';
import '../common/show_more_row.dart';
import '../common/tool_icon_button.dart';
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

    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, {
              'github.newPr': _createPr,
              'github.approve': prNumber == null
                  ? null
                  : () => _approve(prNumber),
              'github.merge': prNumber == null
                  ? null
                  : () => _merge(prNumber),
              'github.rerun': runId == null ? null : () => _rerun(runId),
            })
          : const <ShortcutActivator, VoidCallback>{},
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 360, child: _leftPane(prs, runs, runByBranch)),
          Container(width: 1, color: MacosColors.separatorColor),
          Expanded(child: _mainPane(prs, runs)),
        ],
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
        _sectionHeader(
          context,
          'Pull Requests',
          () => ref.invalidate(pullRequestsProvider(repoPath)),
          onAdd: _createPr,
        ),
        asyncListSection(
          prs,
          'No open pull requests',
          (pr) => _prRow(pr, _headRunFor(pr, runByBranch)),
        ),
        const SizedBox(height: 16),
        _sectionHeader(
          context,
          'Workflow Runs',
          () => ref.invalidate(workflowRunsProvider(repoPath)),
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

  Widget _sectionHeader(
    BuildContext context,
    String title,
    VoidCallback onRefresh, {
    VoidCallback? onAdd,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Text(
            title,
            style: MacosTheme.of(
              context,
            ).typography.caption1.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          if (onAdd != null)
            ToolIconButton(
              icon: CupertinoIcons.add,
              tooltip: 'New pull request',
              size: 15,
              onPressed: onAdd,
            ),
          ToolIconButton(
            icon: CupertinoIcons.refresh,
            tooltip: 'Refresh',
            size: 15,
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }

  Widget _prRow(PullRequest pr, WorkflowRun? headRun) {
    final typography = MacosTheme.of(context).typography;
    final selected = pr.number == _selectedPrNumber;
    return GestureDetector(
      onTap: () => _selectPr(pr.number),
      child: Container(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pr.draft)
              _badge('DRAFT', MacosColors.systemGrayColor)
            else
              _badge('#${pr.number}', MacosColors.systemBlueColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pr.title,
                    style: typography.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (headRun != null) ...[
                        MacosIcon(
                          CupertinoIcons.circle_fill,
                          size: 8,
                          color: ghRunStateColor(headRun.runState),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          '${pr.headRefName} → ${pr.baseRefName}',
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemGrayColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _runRow(WorkflowRun run) {
    final typography = MacosTheme.of(context).typography;
    final selected = run.id == _selectedRunId;
    final rerunnable = run.isRerunnable;
    return GestureDetector(
      onTap: () => _selectRun(run.id),
      child: Container(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
            : const Color(0x00000000),
        padding: const EdgeInsets.fromLTRB(16, 7, 8, 7),
        child: Row(
          children: [
            MacosIcon(
              CupertinoIcons.circle_fill,
              size: 10,
              color: ghRunStateColor(run.runState),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.workflowName.isEmpty ? run.headBranch : run.workflowName,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${run.headBranch}  ·  ${run.shortSha}',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (rerunnable)
              if (_rerunningRuns.contains(run.id))
                const SizedBox(width: 15, height: 15, child: ProgressCircle())
              else
                ToolIconButton(
                  icon: CupertinoIcons.refresh_thick,
                  tooltip: 'Re-run failed jobs',
                  size: 15,
                  color: MacosColors.systemGreenColor,
                  onPressed: () => _rerun(run.id),
                ),
          ],
        ),
      ),
    );
  }

  // ---- Main pane -----------------------------------------------------------

  Widget _mainPane(
    AsyncValue<List<PullRequest>> prs,
    AsyncValue<List<WorkflowRun>> runs,
  ) {
    final typography = MacosTheme.of(context).typography;

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

    return Center(
      child: Text(
        'Select a pull request or workflow run',
        style: typography.body.copyWith(color: MacosColors.systemGrayColor),
      ),
    );
  }

  Widget _runDetail(WorkflowRun? run, int runId) {
    final typography = MacosTheme.of(context).typography;
    final rerunnable = run != null && run.isRerunnable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              MacosIcon(
                CupertinoIcons.circle_fill,
                size: 11,
                color: ghRunStateColor(run?.runState ?? GhRunState.unknown),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  run == null
                      ? 'Run #$runId'
                      : '${run.workflowName}  ·  ${run.headBranch}',
                  style: typography.title3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (rerunnable)
                if (_rerunningRuns.contains(runId))
                  const SizedBox(width: 16, height: 16, child: ProgressCircle())
                else
                  ToolIconButton(
                    icon: CupertinoIcons.refresh_thick,
                    tooltip: 'Re-run failed jobs',
                    size: 16,
                    color: MacosColors.systemGreenColor,
                    onPressed: () => _rerun(runId),
                  ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(child: RunJobsView(repoPath: repoPath, runId: runId)),
      ],
    );
  }

  Widget _prDetail(PullRequest pr) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (pr.draft)
                    _badge('DRAFT', MacosColors.systemGrayColor)
                  else
                    _badge('#${pr.number}', MacosColors.systemBlueColor),
                  const SizedBox(width: 8),
                  Expanded(child: Text(pr.title, style: typography.title3)),
                ],
              ),
              const SizedBox(height: 10),
              _detailLine('Head', pr.headRefName),
              _detailLine('Base', pr.baseRefName),
              if (pr.authorLogin != null)
                _detailLine('Author', '@${pr.authorLogin}'),
              _detailLine('State', pr.merged ? 'merged' : pr.state),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (_checkingOutPrs.contains(pr.number))
                    const ProgressCircle()
                  else
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () => _checkoutPr(pr),
                      child: const Text('Check out'),
                    ),
                  const SizedBox(width: 8),
                  if (_approvingPrs.contains(pr.number))
                    const ProgressCircle()
                  else
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () => _approve(pr.number),
                      child: const Text('Approve'),
                    ),
                  const SizedBox(width: 8),
                  if (_mergingPrs.contains(pr.number))
                    const ProgressCircle()
                  else
                    _mergeButton(pr),
                ],
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
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

  Widget _detailLine(String label, String value) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(child: Text(value, style: typography.body)),
        ],
      ),
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

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
