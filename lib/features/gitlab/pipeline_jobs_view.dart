import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/gitlab/models.dart';
import '../../core/providers/app_providers.dart';
import '../common/tool_icon_button.dart';
import 'status_color.dart';

/// A pipeline's jobs beside the selected job's live log — the GitLab tab's main
/// pane when a pipeline is selected. Selecting a job live-tails its log via
/// `glab ci trace` over the streaming SSH channel.
class PipelineJobsView extends ConsumerStatefulWidget {
  final String repoPath;
  final int pipelineId;

  const PipelineJobsView({
    super.key,
    required this.repoPath,
    required this.pipelineId,
  });

  @override
  ConsumerState<PipelineJobsView> createState() => _PipelineJobsViewState();
}

class _PipelineJobsViewState extends ConsumerState<PipelineJobsView> {
  int? _selectedJobId;

  @override
  void didUpdateWidget(PipelineJobsView old) {
    super.didUpdateWidget(old);
    // Switched pipelines — the previously selected job belongs to the old one.
    if (old.pipelineId != widget.pipelineId) _selectedJobId = null;
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final jobsAsync = ref.watch(
      jobsProvider((widget.repoPath, widget.pipelineId)),
    );

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
                    // Manual refresh only (no auto-polling): a running
                    // pipeline's job statuses otherwise stay frozen until the
                    // pipeline is re-selected. Invalidating re-fetches this
                    // pipeline's jobs (and, since the trace view watches its own
                    // provider, a re-selected job re-tails).
                    ToolIconButton(
                      icon: CupertinoIcons.refresh,
                      tooltip: 'Refresh jobs',
                      size: 15,
                      onPressed: () => ref.invalidate(
                        jobsProvider((widget.repoPath, widget.pipelineId)),
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
        Expanded(
          child: _selectedJobId == null
              ? Center(
                  child: Text(
                    'Select a job to view its log',
                    style: typography.body.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                )
              : _TraceLog(repoPath: widget.repoPath, jobId: _selectedJobId!),
        ),
      ],
    );
  }

  Widget _jobList(BuildContext context, List<Job> jobs) {
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
                  color: ciStatusColor(job.ciStatus),
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
                        '${job.stage}  ·  ${job.status}',
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

/// Live log for one job. The trace stream delivers **incremental** chunks; we
/// accumulate them in a capped buffer (so a long/chatty job can't grow the log
/// unbounded) and only rebuild when a chunk arrives — never re-emitting the
/// whole buffer per chunk, which was quadratic. Auto-scrolls to the tail while
/// the user is at the bottom; a "Jump to latest" pill appears once they scroll
/// away so back-scrolling isn't yanked back down.
class _TraceLog extends ConsumerStatefulWidget {
  final String repoPath;
  final int jobId;

  const _TraceLog({required this.repoPath, required this.jobId});

  @override
  ConsumerState<_TraceLog> createState() => _TraceLogState();
}

class _TraceLogState extends ConsumerState<_TraceLog> {
  final _scroll = ScrollController();
  final List<String> _chunks = [];

  /// Approximate retained scrollback cap (characters). Older chunks drop first.
  static const int _cap = 256 * 1024;

  int _charCount = 0;
  Object? _error;
  bool _loading = true;

  /// Whether new output should keep the view pinned to the tail. Set false once
  /// the user scrolls up; restored when they scroll back to the bottom or tap
  /// the "Jump to latest" pill.
  bool _stick = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(_TraceLog old) {
    super.didUpdateWidget(old);
    // Switched to a different job — reset the accumulated log.
    if (old.jobId != widget.jobId || old.repoPath != widget.repoPath) {
      _chunks.clear();
      _charCount = 0;
      _error = null;
      _loading = true;
      _stick = true;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 8;
    if (atBottom != _stick) setState(() => _stick = atBottom);
  }

  void _append(String chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    _charCount += chunk.length;
    if (_charCount > _cap && _chunks.length > 1) {
      // Figure out how many leading chunks to drop with a read-only scan
      // first, then remove them all in one bulk `removeRange` — `removeAt(0)`
      // in a loop shifts the *entire remaining list* on every single call, so
      // once a long/chatty job has filled the cap, every subsequent chunk for
      // the rest of the job paid that full shift again. A single bulk
      // removal still shifts once, but only once per incoming chunk instead
      // of once per evicted chunk.
      var drop = 0;
      var remaining = _charCount;
      while (drop < _chunks.length - 1 && remaining > _cap) {
        remaining -= _chunks[drop].length;
        drop++;
      }
      if (drop > 0) {
        _chunks.removeRange(0, drop);
        _charCount = remaining;
      }
    }
    if (_charCount > _cap) {
      _chunks
        ..clear()
        ..add('…(earlier output trimmed)…\n')
        ..add(chunk.substring(chunk.length - _cap));
      _charCount = _chunks.fold<int>(0, (n, c) => n + c.length);
    }
    setState(() => _loading = false);
    if (_stick) _jumpToTail();
  }

  void _jumpToTail() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(jobTraceProvider((widget.repoPath, widget.jobId)), (
      previous,
      next,
    ) {
      // Surface a trace failure whenever the value carries an error — it can
      // arrive as a terminal AsyncError OR as a reload that retains the error
      // (AsyncLoading with a prior error), and `next.when(...)` alone would
      // route that latter case to `loading` and silently hide it.
      if (next.hasError) {
        setState(() {
          _error = next.error;
          _loading = false;
        });
        return;
      }
      final chunk = next.value;
      if (chunk != null) _append(chunk);
    });

    final hasContent = _chunks.isNotEmpty || _error != null;

    return Container(
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.all(12),
      child: (_loading && !hasContent)
          ? const Center(child: ProgressCircle())
          : Stack(
              children: [
                Positioned.fill(child: _logList()),
                if (!_stick)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: _JumpToLatestPill(
                      onTap: () {
                        setState(() => _stick = true);
                        _jumpToTail();
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  static const _logStyle = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
    fontSize: 12,
    height: 1.35,
    color: Color(0xFFE0E0E0),
  );

  Widget _logList() {
    final itemCount = _chunks.length + (_error != null ? 1 : 0);
    // One SelectionArea over plain Text chunks: per-chunk SelectableText
    // couldn't carry a selection across the eviction-sized chunk boundaries.
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < _chunks.length) {
            return Text(_chunks[index], style: _logStyle);
          }
          return Text('$_error', style: _logStyle);
        },
      ),
    );
  }
}

class _JumpToLatestPill extends StatelessWidget {
  final VoidCallback onTap;
  const _JumpToLatestPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: MacosColors.systemBlueColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.arrow_down_to_line,
                size: 13,
                color: CupertinoColors.white,
              ),
              SizedBox(width: 6),
              Text(
                'Jump to latest',
                style: TextStyle(fontSize: 12, color: CupertinoColors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
