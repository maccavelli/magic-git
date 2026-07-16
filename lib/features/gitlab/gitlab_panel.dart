import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/gitlab/models.dart';
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
import 'create_mr_sheet.dart';
import 'pipeline_jobs_view.dart';
import 'status_color.dart';

/// GitLab overview in a left-pane / main-panel layout (mirroring History):
/// merge requests and CI/CD pipelines list on the left; selecting one opens the
/// relevant detail on the right — an MR's actions, or a pipeline's jobs and live
/// job logs. Driven through `glab` (JSON contract) over the remote connection.
class GitLabPanel extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether the GitLab tab is the one currently showing. [AppShell] keeps
  /// every visited tab mounted (in an `IndexedStack`) so switching tabs
  /// preserves state — but a mounted-though-invisible panel still counts as a
  /// live listener on its providers, including [jobTraceProvider]'s
  /// `StreamProvider.autoDispose` wrapping a long-running `glab ci trace`.
  /// Without this flag, leaving the GitLab tab never actually stops that
  /// stream (or the SSH channel behind it) since nothing ever unsubscribes.
  final bool isActive;

  const GitLabPanel({super.key, required this.repoPath, this.isActive = true});

  @override
  ConsumerState<GitLabPanel> createState() => _GitLabPanelState();
}

class _GitLabPanelState extends ConsumerState<GitLabPanel> {
  /// Pipelines shown before the "Show more" row expands the list to full
  /// history — CI history is effectively unbounded, and the newest few are
  /// what the panel is for.
  static const int _collapsedPipelineCount = 10;

  // Exactly one of these is non-null: the selected left-pane item.
  int? _selectedMrIid;
  int? _selectedPipelineId;

  // In-flight guards for the outward-facing mutations, keyed by MR iid /
  // pipeline id: without these, the confirm-dialog-to-network-call window is
  // tappable the whole time, so a fast double-tap (or a mis-click during the
  // confirm dialog's dismiss animation) could fire two concurrent
  // approve/merge/retry calls against GitLab.
  final Set<int> _approvingMrs = {};
  final Set<int> _mergingMrs = {};
  final Set<int> _retryingPipelines = {};
  final Set<int> _checkingOutMrs = {};

  String get repoPath => widget.repoPath;

  @override
  void didUpdateWidget(GitLabPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      // The panel isn't keyed by repoPath, so this same State survives a repo
      // switch — without this reset, a selected MR/pipeline id (and its
      // in-flight guards) from the old repo would leak into the new one,
      // potentially rendering an unrelated pipeline's jobs or mutating the
      // wrong project.
      setState(() {
        _selectedMrIid = null;
        _selectedPipelineId = null;
      });
      _approvingMrs.clear();
      _mergingMrs.clear();
      _retryingPipelines.clear();
      _checkingOutMrs.clear();
      _lastPipelines = null;
      _pipeByRef = const {};
    } else if (oldWidget.isActive && !widget.isActive) {
      // Leaving the tab (same repo, still mounted inside AppShell's
      // IndexedStack) — clear the selection so the pipeline-jobs/job-trace
      // subtree unmounts, letting jobTraceProvider's stream actually stop
      // instead of tailing `glab ci trace` in the background indefinitely.
      setState(() {
        _selectedMrIid = null;
        _selectedPipelineId = null;
      });
    }
  }

  // Memoized branch→pipeline fusion: recomputed only when the pipelines list
  // *instance* changes (Riverpod hands back the same list across rebuilds
  // until the provider is invalidated), so an unrelated setState (row
  // selection, an in-flight guard toggling) doesn't re-walk the pipeline list.
  List<Pipeline>? _lastPipelines;
  Map<String, Pipeline> _pipeByRef = const {};

  Map<String, Pipeline> _pipeByRefFor(List<Pipeline> pipelines) {
    if (identical(pipelines, _lastPipelines)) return _pipeByRef;
    _lastPipelines = pipelines;
    final map = <String, Pipeline>{};
    for (final p in pipelines) {
      map.putIfAbsent(p.ref, () => p);
    }
    return _pipeByRef = map;
  }

  /// Whether pipeline [p] belongs to merge request [mr]. A plain branch
  /// pipeline carries `ref` as the source branch name — but any project with
  /// GitLab's "pipelines for merge requests" CI/CD setting enabled (common)
  /// instead runs pipelines against the synthetic
  /// `refs/merge-requests/<iid>/head` (detached MR pipeline) or
  /// `refs/merge-requests/<iid>/merge` (merged-results pipeline) refs — never
  /// the branch name. Both forms have to be checked, or such a project's MRs
  /// would never show an associated pipeline/CI status.
  bool _pipelineMatchesMr(Pipeline p, MergeRequest mr) =>
      p.ref == mr.sourceBranch ||
      p.ref == 'refs/merge-requests/${mr.iid}/head' ||
      p.ref == 'refs/merge-requests/${mr.iid}/merge';

  /// The pipeline associated with [mr] (see [_pipelineMatchesMr]), or null if
  /// none. [pipeByRef] is already deduped to one (the most recent) pipeline
  /// per distinct ref, so this is at most a handful of comparisons rather than
  /// a re-scan of every pipeline.
  Pipeline? _headPipelineFor(MergeRequest mr, Map<String, Pipeline> pipeByRef) {
    for (final p in pipeByRef.values) {
      if (_pipelineMatchesMr(p, mr)) return p;
    }
    return null;
  }

  void _selectMr(int iid) => setState(() {
    _selectedMrIid = iid;
    _selectedPipelineId = null;
  });

  void _selectPipeline(int id) => setState(() {
    _selectedPipelineId = id;
    _selectedMrIid = null;
  });

  @override
  Widget build(BuildContext context) {
    // No remote at all → the glab-backed MR/pipeline views can't work; show a
    // friendly notice rather than a raw glab error. CONFIGURED remotes, not
    // remote-tracking refs — an empty repo with a wired origin has no remote
    // refs yet and must still get its forge features. Null (still loading)
    // falls through. Mirrors repo_status_view's "No remote detected".
    final remotes = ref.watch(remotesProvider(repoPath)).value;
    if (remotes != null && remotes.isEmpty) {
      return const NoRemoteNotice('GitLab features');
    }
    final mrs = ref.watch(mergeRequestsProvider(repoPath));
    final pipelines = ref.watch(pipelinesProvider(repoPath));

    // Fuse the two lists we already have: map each branch to its most recent
    // pipeline (newest-first, so the first hit per ref wins) for an MR's inline
    // CI status.
    final pipeByRef = _pipeByRefFor(pipelines.value ?? const <Pipeline>[]);

    final keymap = ref.watch(keymapProvider);
    final mrIid = _selectedMrIid;
    final pipelineId = _selectedPipelineId;

    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, {
              'gitlab.newMr': _createMr,
              'gitlab.approve': mrIid == null ? null : () => _approve(mrIid),
              'gitlab.merge': mrIid == null ? null : () => _merge(mrIid),
              'gitlab.retry': pipelineId == null
                  ? null
                  : () => _retry(pipelineId),
            })
          : const <ShortcutActivator, VoidCallback>{},
      child: ResizableMasterDetail(
        paneId: PaneId.forgeList,
        master: _leftPane(mrs, pipelines, pipeByRef),
        detail: _mainPane(mrs, pipelines),
      ),
    );
  }

  // ---- Left pane -----------------------------------------------------------

  Widget _leftPane(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
    Map<String, Pipeline> pipeByRef,
  ) {
    final fullHistory = ref.watch(pipelinesScopeProvider(repoPath));
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ForgeSectionHeader(
          'Merge Requests',
          onRefresh: () => ref.invalidate(mergeRequestsProvider(repoPath)),
          onAdd: _createMr,
          addTooltip: 'New merge request',
        ),
        asyncListSection(
          mrs,
          'No open merge requests',
          (mr) => _mrRow(mr, _headPipelineFor(mr, pipeByRef)),
        ),
        const SizedBox(height: 16),
        ForgeSectionHeader(
          'Pipelines',
          onRefresh: () => ref.invalidate(pipelinesProvider(repoPath)),
        ),
        // Newest 10 by default; "Show more" flips the scope notifier, which
        // re-fetches this same provider with the full (bounded) history —
        // skipLoadingOnReload keeps the current rows up while that runs, and
        // the busy row below is the only loading signal.
        asyncListSection(
          pipelines,
          'No recent pipelines',
          (p) => _pipelineRow(p),
          skipLoadingOnReload: true,
          limit: fullHistory ? null : _collapsedPipelineCount,
          overflow: (hidden) => ShowMoreRow(
            label: 'Show all pipelines',
            onTap: () =>
                ref.read(pipelinesScopeProvider(repoPath).notifier).expand(),
          ),
        ),
        if (fullHistory && pipelines.isLoading)
          const ShowMoreRow(label: 'Loading pipeline history…', busy: true),
      ],
    );
  }

  Widget _mrRow(MergeRequest mr, Pipeline? headPipeline) {
    return ChangeRequestRow(
      badge: mr.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('!${mr.iid}', MacosColors.systemBlueColor),
      title: mr.title,
      branches: '${mr.sourceBranch} → ${mr.targetBranch}',
      ciDotColor: headPipeline == null
          ? null
          : ciStatusColor(headPipeline.ciStatus),
      selected: mr.iid == _selectedMrIid,
      onTap: () => _selectMr(mr.iid),
    );
  }

  Widget _pipelineRow(Pipeline pipeline) {
    return CiRunRow(
      dotColor: ciStatusColor(pipeline.ciStatus),
      title: '${pipeline.ref}  ·  ${pipeline.shortSha}',
      selected: pipeline.id == _selectedPipelineId,
      onTap: () => _selectPipeline(pipeline.id),
      // Retry is green; only plain refresh icons stay blue.
      trailing: pipeline.isRetryable
          ? InFlightIconButton(
              busy: _retryingPipelines.contains(pipeline.id),
              icon: CupertinoIcons.refresh_thick,
              tooltip: 'Retry pipeline',
              size: 15,
              color: MacosColors.systemGreenColor,
              onPressed: () => _retry(pipeline.id),
            )
          : null,
    );
  }

  // ---- Main pane -----------------------------------------------------------

  Widget _mainPane(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
  ) {
    if (_selectedPipelineId != null) {
      Pipeline? pipeline;
      for (final p in pipelines.value ?? const <Pipeline>[]) {
        if (p.id == _selectedPipelineId) pipeline = p;
      }
      return _pipelineDetail(pipeline, _selectedPipelineId!);
    }

    if (_selectedMrIid != null) {
      MergeRequest? mr;
      for (final m in mrs.value ?? const <MergeRequest>[]) {
        if (m.iid == _selectedMrIid) mr = m;
      }
      if (mr != null) return _mrDetail(mr);
    }

    return const CenteredHint('Select a merge request or pipeline');
  }

  Widget _pipelineDetail(Pipeline? pipeline, int pipelineId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CiDetailHeader(
          dotColor: ciStatusColor(pipeline?.ciStatus ?? CiStatus.unknown),
          title: pipeline == null
              ? 'Pipeline #$pipelineId'
              : 'Pipeline #$pipelineId  ·  ${pipeline.ref}',
          trailing: pipeline != null && pipeline.isRetryable
              ? InFlightIconButton(
                  busy: _retryingPipelines.contains(pipelineId),
                  icon: CupertinoIcons.refresh_thick,
                  tooltip: 'Retry pipeline',
                  size: 16,
                  color: MacosColors.systemGreenColor,
                  onPressed: () => _retry(pipelineId),
                )
              : null,
        ),
        Expanded(
          child: PipelineJobsView(repoPath: repoPath, pipelineId: pipelineId),
        ),
      ],
    );
  }

  Widget _mrDetail(MergeRequest mr) {
    return ChangeRequestDetail(
      badge: mr.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('!${mr.iid}', MacosColors.systemBlueColor),
      title: mr.title,
      lines: [
        DetailLine('Source', mr.sourceBranch),
        DetailLine('Target', mr.targetBranch),
        if (mr.authorUsername != null)
          DetailLine('Author', '@${mr.authorUsername}'),
        DetailLine('State', mr.state),
      ],
      actions: [
        InFlightPushButton(
          busy: _checkingOutMrs.contains(mr.iid),
          label: 'Check out',
          secondary: true,
          onPressed: () => _checkoutMr(mr),
        ),
        InFlightPushButton(
          busy: _approvingMrs.contains(mr.iid),
          label: 'Approve',
          secondary: true,
          onPressed: () => _approve(mr.iid),
        ),
        if (_mergingMrs.contains(mr.iid))
          const ProgressCircle()
        else
          _mergeButton(mr),
      ],
    );
  }

  /// The "Merge" action, disabled (greyed out, `onPressed: null`) with an
  /// explanatory tooltip when [mr] is a draft — GitLab's API rejects merging
  /// a draft MR outright, so this catches it client-side instead of letting
  /// the user hit a raw remote error. The pulldown beside it offers the
  /// squash merge the API always supported but the UI never exposed
  /// (mirroring the GitHub panel's merge pulldown; GitLab has no per-merge
  /// rebase — that's a project setting — so squash is the only entry).
  Widget _mergeButton(MergeRequest mr) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PushButton(
          controlSize: ControlSize.large,
          onPressed: mr.draft ? null : () => _merge(mr.iid),
          child: const Text('Merge'),
        ),
        if (!mr.draft) ...[
          const SizedBox(width: 4),
          MacosPulldownButton(
            icon: CupertinoIcons.chevron_down,
            items: [
              MacosPulldownMenuItem(
                title: const Text('Squash and merge'),
                onTap: () => _merge(mr.iid, squash: true),
              ),
            ],
          ),
        ],
      ],
    );
    if (!mr.draft) return row;
    return MacosTooltip(
      message: "Draft merge requests can't be merged — mark it ready first.",
      child: row,
    );
  }

  // ---- Actions -------------------------------------------------------------

  void _createMr() {
    showMacosSheet<void>(
      context: context,
      builder: (_) =>
          EscapeDismissible(child: CreateMrSheet(repoPath: repoPath)),
    );
  }

  Future<void> _approve(int iid) async {
    if (_approvingMrs.contains(iid)) return; // already in flight
    // Captured up front: the confirm dialog spans an await, and the active
    // repo can change (connection switcher) before it resolves — the
    // mutation and its follow-up invalidation must still target the repo
    // this MR actually belongs to, not whatever is active by the time we
    // get here.
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Approve merge request',
      message: 'Approve !$iid on the remote GitLab project?',
      confirmLabel: 'Approve',
    );
    if (!ok || !mounted) return;
    // The in-flight guard is added *after* the confirm resolves, on purpose:
    // it also drives the button's ProgressCircle, which must mean "the
    // approve is running", not "a confirm dialog is open". Adding it earlier
    // would show a spinner while the user is still merely being asked to
    // confirm. Re-entry during the dialog window is already blocked by the
    // modal barrier (the button can't be tapped again behind it), so the guard
    // here needn't cover that window too.
    setState(() => _approvingMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.approveMergeRequest(repoPath, iid),
    );
    if (!mounted) return;
    setState(() => _approvingMrs.remove(iid));
    if (success) {
      ref.invalidate(mergeRequestsProvider(repoPath));
    }
  }

  Future<void> _merge(int iid, {bool squash = false}) async {
    if (_mergingMrs.contains(iid)) return; // already in flight
    final repoPath = this.repoPath; // see _approve
    final verb = squash ? 'Squash-merge' : 'Merge';
    final ok = await confirmAction(
      context,
      title: 'Merge merge request',
      message: '$verb !$iid into its target branch?',
      confirmLabel: verb,
    );
    if (!ok || !mounted) return;
    // Guard added after confirm so its spinner means "merging", not "confirm
    // dialog open" — see _approve.
    setState(() => _mergingMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.mergeMergeRequest(repoPath, iid, squash: squash),
    );
    if (!mounted) return;
    setState(() => _mergingMrs.remove(iid));
    if (success) {
      // The MR is gone after a merge — clear the detail selection.
      setState(() => _selectedMrIid = null);
      ref.invalidate(mergeRequestsProvider(repoPath));
    }
  }

  /// Checks out the MR's source branch (`glab mr checkout`) behind the dirty-tree
  /// guardrail, then refreshes the working-tree views since HEAD has moved.
  Future<void> _checkoutMr(MergeRequest mr) async {
    if (_checkingOutMrs.contains(mr.iid)) return; // already in flight
    final repoPath = this.repoPath; // see _approve
    final glab = ref.read(glabServiceProvider);
    // Guard spans guardedBranchSwitch's own (conditional) confirm dialog too —
    // unlike _approve/_merge/_retry there's no separate confirm step to add it
    // after, but that dialog is just as modal, so re-entry during it is
    // already blocked by the same barrier; see _approve.
    setState(() => _checkingOutMrs.add(mr.iid));
    await guardedBranchSwitch(
      context,
      ref,
      repoPath,
      () => glab.checkoutMergeRequest(repoPath, mr.iid),
    );
    // guardedBranchSwitch spans a confirm dialog plus a remote checkout over
    // SSH — the widget can be gone by the time it resolves (panel closed,
    // connection dropped) before `ref` is touched again.
    if (!mounted) return;
    setState(() => _checkingOutMrs.remove(mr.iid));
    // Refresh even when the switch didn't complete: the guard's stash step
    // can succeed while the checkout itself fails, and the panel must show
    // that intermediate state rather than pretend nothing happened.
    refreshAfterMutation(ref, repoPath);
  }

  Future<void> _retry(int id) async {
    if (_retryingPipelines.contains(id)) return; // already in flight
    final repoPath = this.repoPath; // see _approve
    final ok = await confirmAction(
      context,
      title: 'Retry pipeline',
      message: 'Retry failed jobs in pipeline #$id?',
      confirmLabel: 'Retry',
    );
    if (!ok || !mounted) return;
    // Guard added after confirm so its spinner means "retrying", not "confirm
    // dialog open" — see _approve.
    setState(() => _retryingPipelines.add(id));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.retryPipeline(repoPath, id),
    );
    if (!mounted) return;
    setState(() => _retryingPipelines.remove(id));
    if (success) {
      ref.invalidate(pipelinesProvider(repoPath));
      ref.invalidate(jobsProvider((repoPath, id)));
    }
  }

}
