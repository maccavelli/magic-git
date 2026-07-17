import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/display_error.dart';
import '../common/resizable_master_detail.dart';
import '../forge/forge_widgets.dart';
import 'status_color.dart';

/// A workflow run's jobs beside the selected job's log — the Forge tab's main
/// pane (GitHub) when a run is selected. Job statuses update live via
/// [runJobsProvider]'s polling stream; a completed job's full log is fetched via
/// [runJobLogProvider]. GitHub exposes no live per-line log stream (unlike
/// GitLab's `glab ci trace`), so an in-progress job shows a placeholder until it
/// finishes.
class RunJobsView extends ConsumerStatefulWidget {
  final String repoPath;
  final int runId;

  const RunJobsView({super.key, required this.repoPath, required this.runId});

  @override
  ConsumerState<RunJobsView> createState() => _RunJobsViewState();
}

class _RunJobsViewState extends ConsumerState<RunJobsView> {
  int? _selectedJobId;

  @override
  void didUpdateWidget(RunJobsView old) {
    super.didUpdateWidget(old);
    // Switched runs — the previously selected job belongs to the old one.
    if (old.runId != widget.runId) _selectedJobId = null;
  }

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(runJobsProvider((widget.repoPath, widget.runId)));
    final jobs = jobsAsync.value ?? const <GhJob>[];

    GhJob? selectedJob;
    for (final j in jobs) {
      if (j.id == _selectedJobId) selectedJob = j;
    }

    return ResizableMasterDetail(
      paneId: PaneId.jobsList,
      // The log pane tolerates narrow (it scrolls horizontally).
      detailFloor: 240,
      master: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ForgeSectionHeader(
            'Jobs',
            refreshTooltip: 'Refresh jobs',
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            onRefresh: () => ref.invalidate(
              runJobsProvider((widget.repoPath, widget.runId)),
            ),
          ),
          Expanded(
            child: jobsAsync.when(
              loading: () => const Center(child: ProgressCircle()),
              error: (err, _) => PaneError(err),
              data: (jobs) => _jobList(context, jobs),
            ),
          ),
        ],
      ),
      // A selected job that the (errored) list couldn't resolve should show the
      // error, not the "still running" placeholder that _logPane falls back to
      // for a null job — that would confidently mis-state a failed load.
      detail: _selectedJobId != null && selectedJob == null && jobsAsync.hasError
          ? PaneError(jobsAsync.error!)
          : _logPane(context, selectedJob),
    );
  }

  Widget _logPane(BuildContext context, GhJob? job) {
    final typography = MacosTheme.of(context).typography;
    if (_selectedJobId == null) {
      return const CenteredHint('Select a job to view its log');
    }
    // GitHub only serves logs once a job completes. Also treat a not-yet-known
    // job (still loading, or dropped from the list after a re-run changed job
    // ids) as "not ready" rather than fetching a log for it — `gh run view
    // --log` would just error for a running/unknown job.
    if (job == null || job.status != 'completed') {
      return Container(
        color: AppTheme.terminalBackground,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          'This job is still running.\nLogs are available once it completes.',
          textAlign: TextAlign.center,
          style: typography.body.copyWith(color: kLogMutedColor),
        ),
      );
    }
    return _JobLog(repoPath: widget.repoPath, jobId: _selectedJobId!);
  }

  Widget _jobList(BuildContext context, List<GhJob> jobs) {
    final typography = MacosTheme.of(context).typography;
    if (jobs.isEmpty) {
      return Center(child: Text('No jobs', style: typography.body));
    }
    return ListView.builder(
      itemCount: jobs.length,
      itemBuilder: (context, index) {
        final job = jobs[index];
        final selected = job.id == _selectedJobId;
        return JobRow(
          name: job.name,
          caption: job.conclusion ?? job.status,
          dotColor: ghRunStateColor(job.runState),
          selected: selected,
          onTap: () => setState(() => _selectedJobId = job.id),
        );
      },
    );
  }

}

/// A completed job's log, fetched once via `gh run view --job <id> --log`.
class _JobLog extends ConsumerWidget {
  final String repoPath;
  final int jobId;

  const _JobLog({required this.repoPath, required this.jobId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logAsync = ref.watch(runJobLogProvider((repoPath, jobId)));
    return Container(
      color: AppTheme.terminalBackground,
      padding: const EdgeInsets.all(12),
      child: logAsync.when(
        loading: () => const Center(child: ProgressCircle()),
        error: (err, _) => SelectableText(
          displayError(err),
          style: kJobLogStyle.copyWith(color: MacosColors.systemRedColor),
        ),
        data: (log) => log.trim().isEmpty
            ? const Center(
                child: Text(
                  'No log output.',
                  style: TextStyle(color: kLogMutedColor),
                ),
              )
            : SingleChildScrollView(
                child: SelectableText(log, style: kJobLogStyle),
              ),
      ),
    );
  }
}
