import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../common/tool_icon_button.dart';
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
    final typography = MacosTheme.of(context).typography;
    final jobsAsync = ref.watch(runJobsProvider((widget.repoPath, widget.runId)));
    final jobs = jobsAsync.value ?? const <GhJob>[];

    GhJob? selectedJob;
    for (final j in jobs) {
      if (j.id == _selectedJobId) selectedJob = j;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 240,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                child: Row(
                  children: [
                    Text(
                      'Jobs',
                      style: typography.caption1.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    ToolIconButton(
                      icon: CupertinoIcons.refresh,
                      tooltip: 'Refresh jobs',
                      size: 15,
                      onPressed: () => ref.invalidate(
                        runJobsProvider((widget.repoPath, widget.runId)),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: jobsAsync.when(
                  loading: () => const Center(child: ProgressCircle()),
                  error: (err, _) => _error(context, err),
                  data: (jobs) => _jobList(context, jobs),
                ),
              ),
            ],
          ),
        ),
        Container(width: 1, color: MacosColors.separatorColor),
        Expanded(child: _logPane(context, selectedJob)),
      ],
    );
  }

  Widget _logPane(BuildContext context, GhJob? job) {
    final typography = MacosTheme.of(context).typography;
    if (_selectedJobId == null) {
      return Center(
        child: Text(
          'Select a job to view its log',
          style: typography.body.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }
    // GitHub only serves logs once a job completes. Also treat a not-yet-known
    // job (still loading, or dropped from the list after a re-run changed job
    // ids) as "not ready" rather than fetching a log for it — `gh run view
    // --log` would just error for a running/unknown job.
    if (job == null || job.status != 'completed') {
      return Container(
        color: const Color(0xFF1E1E1E),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          'This job is still running.\nLogs are available once it completes.',
          textAlign: TextAlign.center,
          style: typography.body.copyWith(color: const Color(0xFF9E9E9E)),
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
        return GestureDetector(
          onTap: () => setState(() => _selectedJobId = job.id),
          child: Container(
            color: selected
                ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
                : const Color(0x00000000),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                MacosIcon(
                  CupertinoIcons.circle_fill,
                  size: 9,
                  color: ghRunStateColor(job.runState),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.name,
                        style: typography.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        job.conclusion ?? job.status,
                        style: typography.caption1.copyWith(
                          color: MacosColors.systemGrayColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _error(BuildContext context, Object err) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        '$err',
        style: MacosTheme.of(
          context,
        ).typography.body.copyWith(color: MacosColors.systemRedColor),
      ),
    ),
  );
}

/// A completed job's log, fetched once via `gh run view --job <id> --log`.
class _JobLog extends ConsumerWidget {
  final String repoPath;
  final int jobId;

  const _JobLog({required this.repoPath, required this.jobId});

  static const _logStyle = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
    fontSize: 12,
    height: 1.35,
    color: Color(0xFFE0E0E0),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logAsync = ref.watch(runJobLogProvider((repoPath, jobId)));
    return Container(
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.all(12),
      child: logAsync.when(
        loading: () => const Center(child: ProgressCircle()),
        error: (err, _) => SelectableText(
          '$err',
          style: _logStyle.copyWith(color: MacosColors.systemRedColor),
        ),
        data: (log) => log.trim().isEmpty
            ? const Center(
                child: Text(
                  'No log output.',
                  style: TextStyle(color: Color(0xFF9E9E9E)),
                ),
              )
            : SingleChildScrollView(
                child: SelectableText(log, style: _logStyle),
              ),
      ),
    );
  }
}
