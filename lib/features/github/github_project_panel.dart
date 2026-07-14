import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/github/models.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/label_colors.dart';
import '../common/tool_icon_button.dart';

/// Read-only GitHub repository overview: one GraphQL round-trip for issues,
/// labels, milestones, and releases. Mirrors GitLab's `ProjectPanel`.
class GitHubProjectPanel extends ConsumerWidget {
  final String repoPath;

  const GitHubProjectPanel({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No remote at all → the gh-backed dashboard can't work; show a friendly
    // notice rather than a raw gh error. Null (refs still loading) falls
    // through to the normal load. Mirrors the GitLab ProjectPanel, which had
    // this guard while this twin was missing it.
    final refs = ref.watch(refsProvider(repoPath)).value;
    if (refs != null && !refs.any((r) => r.isRemote)) {
      return const NoRemoteNotice('project features');
    }
    final dashboard = ref.watch(githubProjectDashboardProvider(repoPath));

    // Non-fatal partial-data warning from the dashboard's GraphQL query —
    // the sheets surfaced this while the panels silently rendered the
    // incomplete data. Only read once a dashboard actually landed.
    final warning = dashboard.hasValue
        ? ref.read(ghServiceProvider).lastGraphqlWarning
        : null;

    return dashboard.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (data) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (warning != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DashboardWarningBanner(warning),
            ),
          _header(context, 'Issues', () {
            ref.invalidate(githubProjectDashboardProvider(repoPath));
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
            ref.invalidate(githubProjectDashboardProvider(repoPath));
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
            ref.invalidate(githubProjectDashboardProvider(repoPath));
          }),
          data.milestones.isEmpty
              ? const SectionEmpty('No open milestones')
              : Column(
                  children: data.milestones
                      .map((m) => _milestoneRow(context, m))
                      .toList(),
                ),
          const SizedBox(height: 14),
          _header(context, 'Releases', () {
            ref.invalidate(githubProjectDashboardProvider(repoPath));
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

  Widget _issueRow(BuildContext context, GhIssue issue) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${issue.number}',
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
                if (issue.authorLogin != null)
                  Text(
                    '@${issue.authorLogin}',
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

  Widget _labelChip(GhLabel label) {
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

  Widget _milestoneRow(BuildContext context, GhMilestone milestone) {
    final typography = MacosTheme.of(context).typography;
    // dueOn is an ISO timestamp (e.g. 2026-08-01T00:00:00Z); show just the date.
    final due = milestone.dueOn?.split('T').first;
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
          if (due != null && due.isNotEmpty)
            Text(
              'due $due',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _releaseRow(BuildContext context, GhRelease release) {
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
