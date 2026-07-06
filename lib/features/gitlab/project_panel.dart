import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' hide Label;
import '../../core/gitlab/models.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
import '../common/tool_icon_button.dart';
import 'status_color.dart';

/// Read-only GitLab project overview: one GraphQL round-trip for issues, labels,
/// milestones, and releases.
class ProjectPanel extends ConsumerWidget {
  final String repoPath;

  const ProjectPanel({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No remote at all → the glab-backed dashboard can't work; show a friendly
    // notice rather than a raw glab error. Null (refs still loading) falls
    // through to the normal load. Mirrors repo_status_view's "No remote
    // detected".
    final refs = ref.watch(refsProvider(repoPath)).value;
    if (refs != null && !refs.any((r) => r.isRemote)) {
      return const NoRemoteNotice('project features');
    }
    final dashboard = ref.watch(projectDashboardProvider(repoPath));

    return dashboard.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (data) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _header(context, 'Issues', () {
            ref.invalidate(projectDashboardProvider(repoPath));
          }),
          data.issues.isEmpty
              ? const SectionEmpty('No open issues')
              : Column(
                  children: data.issues
                      .map((i) => _issueRow(context, i))
                      .toList(),
                ),
          const SizedBox(height: 14),
          _header(context, 'Labels', () {
            ref.invalidate(projectDashboardProvider(repoPath));
          }),
          data.labels.isEmpty
              ? const SectionEmpty('No labels')
              : Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: data.labels.map(_labelChip).toList(),
                  ),
                ),
          const SizedBox(height: 14),
          _header(context, 'Milestones', () {
            ref.invalidate(projectDashboardProvider(repoPath));
          }),
          data.milestones.isEmpty
              ? const SectionEmpty('No active milestones')
              : Column(
                  children: data.milestones
                      .map((m) => _milestoneRow(context, m))
                      .toList(),
                ),
          const SizedBox(height: 14),
          _header(context, 'Releases', () {
            ref.invalidate(projectDashboardProvider(repoPath));
          }),
          data.releases.isEmpty
              ? const SectionEmpty('No releases')
              : Column(
                  children: data.releases
                      .map((r) => _releaseRow(context, r))
                      .toList(),
                ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String title, VoidCallback onRefresh) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
      child: Row(
        children: [
          Text(
            title,
            style: MacosTheme.of(
              context,
            ).typography.caption1.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
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

  Widget _issueRow(BuildContext context, Issue issue) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${issue.iid}',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issue.title,
                  style: typography.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (issue.authorUsername != null)
                  Text(
                    '@${issue.authorUsername}',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelChip(Label label) {
    final bg = parseLabelColor(label.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label.name,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: labelTextColor(bg),
        ),
      ),
    );
  }

  Widget _milestoneRow(BuildContext context, Milestone milestone) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const MacosIcon(CupertinoIcons.flag, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              milestone.title,
              style: typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (milestone.dueDate != null)
            Text(
              'due ${milestone.dueDate}',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _releaseRow(BuildContext context, Release release) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.tag,
            size: 14,
            color: MacosColors.systemOrangeColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              release.name.isEmpty ? release.tagName : release.name,
              style: typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            release.tagName,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
        ],
      ),
    );
  }
}
