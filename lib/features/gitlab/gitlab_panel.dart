import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/gitlab/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/branch_switch.dart';
import '../common/escape_dismissible.dart';
import '../common/panel_shortcuts.dart';
import '../common/tool_icon_button.dart';
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
    // friendly notice rather than a raw glab error. Null (refs still loading)
    // falls through. Mirrors repo_status_view's "No remote detected".
    final refs = ref.watch(refsProvider(repoPath)).value;
    if (refs != null && !refs.any((r) => r.isRemote)) {
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 360, child: _leftPane(mrs, pipelines, pipeByRef)),
          Container(width: 1, color: MacosColors.separatorColor),
          Expanded(child: _mainPane(mrs, pipelines)),
        ],
      ),
    );
  }

  // ---- Left pane -----------------------------------------------------------

  Widget _leftPane(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
    Map<String, Pipeline> pipeByRef,
  ) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _sectionHeader(
          context,
          'Merge Requests',
          () => ref.invalidate(mergeRequestsProvider(repoPath)),
          onAdd: _createMr,
        ),
        asyncListSection(
          mrs,
          'No open merge requests',
          (mr) => _mrRow(mr, _headPipelineFor(mr, pipeByRef)),
        ),
        const SizedBox(height: 16),
        _sectionHeader(
          context,
          'Pipelines',
          () => ref.invalidate(pipelinesProvider(repoPath)),
        ),
        asyncListSection(
          pipelines,
          'No recent pipelines',
          (p) => _pipelineRow(p),
        ),
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
              tooltip: 'New merge request',
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

  Widget _mrRow(MergeRequest mr, Pipeline? headPipeline) {
    final typography = MacosTheme.of(context).typography;
    final selected = mr.iid == _selectedMrIid;
    return GestureDetector(
      onTap: () => _selectMr(mr.iid),
      child: Container(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mr.draft)
              _badge('DRAFT', MacosColors.systemGrayColor)
            else
              _badge('!${mr.iid}', MacosColors.systemBlueColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mr.title,
                    style: typography.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (headPipeline != null) ...[
                        MacosIcon(
                          CupertinoIcons.circle_fill,
                          size: 8,
                          color: ciStatusColor(headPipeline.ciStatus),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          '${mr.sourceBranch} → ${mr.targetBranch}',
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

  Widget _pipelineRow(Pipeline pipeline) {
    final typography = MacosTheme.of(context).typography;
    final selected = pipeline.id == _selectedPipelineId;
    final retryable = pipeline.isRetryable;
    return GestureDetector(
      onTap: () => _selectPipeline(pipeline.id),
      child: Container(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
            : const Color(0x00000000),
        // Right inset matches the section headers so every retry icon lines up
        // flush against the same right margin (never indented past a refresh).
        padding: const EdgeInsets.fromLTRB(16, 7, 8, 7),
        child: Row(
          children: [
            // A colored dot conveys pass/fail at a glance; the textual status and
            // the jobs/logs icon are gone — the row itself opens the logs, and
            // only the retry action remains on the right margin.
            MacosIcon(
              CupertinoIcons.circle_fill,
              size: 10,
              color: ciStatusColor(pipeline.ciStatus),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${pipeline.ref}  ·  ${pipeline.shortSha}',
                style: typography.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (retryable)
              if (_retryingPipelines.contains(pipeline.id))
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: ProgressCircle(),
                )
              else
                // Retry is green; only plain refresh icons stay blue.
                ToolIconButton(
                  icon: CupertinoIcons.refresh_thick,
                  tooltip: 'Retry pipeline',
                  size: 15,
                  color: MacosColors.systemGreenColor,
                  onPressed: () => _retry(pipeline.id),
                ),
          ],
        ),
      ),
    );
  }

  // ---- Main pane -----------------------------------------------------------

  Widget _mainPane(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
  ) {
    final typography = MacosTheme.of(context).typography;

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

    return Center(
      child: Text(
        'Select a merge request or pipeline',
        style: typography.body.copyWith(color: MacosColors.systemGrayColor),
      ),
    );
  }

  Widget _pipelineDetail(Pipeline? pipeline, int pipelineId) {
    final typography = MacosTheme.of(context).typography;
    final retryable = pipeline != null && pipeline.isRetryable;
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
                color: ciStatusColor(pipeline?.ciStatus ?? CiStatus.unknown),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pipeline == null
                      ? 'Pipeline #$pipelineId'
                      : 'Pipeline #$pipelineId  ·  ${pipeline.ref}',
                  style: typography.title3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The only pipeline action on the main panel's right margin —
              // green, flush right (only plain refresh icons stay blue).
              if (retryable)
                if (_retryingPipelines.contains(pipelineId))
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: ProgressCircle(),
                  )
                else
                  ToolIconButton(
                    icon: CupertinoIcons.refresh_thick,
                    tooltip: 'Retry pipeline',
                    size: 16,
                    color: MacosColors.systemGreenColor,
                    onPressed: () => _retry(pipelineId),
                  ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: PipelineJobsView(repoPath: repoPath, pipelineId: pipelineId),
        ),
      ],
    );
  }

  Widget _mrDetail(MergeRequest mr) {
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
                  if (mr.draft)
                    _badge('DRAFT', MacosColors.systemGrayColor)
                  else
                    _badge('!${mr.iid}', MacosColors.systemBlueColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(mr.title, style: typography.title3),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _detailLine('Source', mr.sourceBranch),
              _detailLine('Target', mr.targetBranch),
              if (mr.authorUsername != null)
                _detailLine('Author', '@${mr.authorUsername}'),
              _detailLine('State', mr.state),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (_checkingOutMrs.contains(mr.iid))
                    const ProgressCircle()
                  else
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () => _checkoutMr(mr),
                      child: const Text('Check out'),
                    ),
                  const SizedBox(width: 8),
                  if (_approvingMrs.contains(mr.iid))
                    const ProgressCircle()
                  else
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () => _approve(mr.iid),
                      child: const Text('Approve'),
                    ),
                  const SizedBox(width: 8),
                  if (_mergingMrs.contains(mr.iid))
                    const ProgressCircle()
                  else
                    _mergeButton(mr),
                ],
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
      ],
    );
  }

  /// The "Merge" action, disabled (greyed out, `onPressed: null`) with an
  /// explanatory tooltip when [mr] is a draft — GitLab's API rejects merging
  /// a draft MR outright, so this catches it client-side instead of letting
  /// the user hit a raw remote error. Mirrors this panel's existing
  /// disabled-when-not-applicable idiom (e.g. the retry icon only appearing
  /// for a `retryable` pipeline) and `CreateMrSheet`'s `onPressed: condition
  /// ? action : null` pattern.
  Widget _mergeButton(MergeRequest mr) {
    final button = PushButton(
      controlSize: ControlSize.large,
      onPressed: mr.draft ? null : () => _merge(mr.iid),
      child: const Text('Merge'),
    );
    if (!mr.draft) return button;
    return MacosTooltip(
      message: "Draft merge requests can't be merged — mark it ready first.",
      child: button,
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

  Future<void> _merge(int iid) async {
    if (_mergingMrs.contains(iid)) return; // already in flight
    final repoPath = this.repoPath; // see _approve
    final ok = await confirmAction(
      context,
      title: 'Merge merge request',
      message: 'Merge !$iid into its target branch?',
      confirmLabel: 'Merge',
    );
    if (!ok || !mounted) return;
    // Guard added after confirm so its spinner means "merging", not "confirm
    // dialog open" — see _approve.
    setState(() => _mergingMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.mergeMergeRequest(repoPath, iid),
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
    final switched = await guardedBranchSwitch(
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
    if (switched) {
      ref.invalidate(statusProvider(repoPath));
      ref.invalidate(refsProvider(repoPath));
      ref.invalidate(logProvider(repoPath));
    }
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
