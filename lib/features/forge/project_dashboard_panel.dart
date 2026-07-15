import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge_dashboard.dart';
import '../common/async_views.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/label_colors.dart';
import '../common/tool_icon_button.dart';

/// Read-only forge project overview: issues, labels, milestones, and releases
/// from one GraphQL round-trip. One widget for both forges — the GitHub and
/// GitLab versions of this panel were ~95% line-identical twins (three of the
/// five row builders byte-identical, the other two differing only in model
/// field names), which the shared [ForgeProjectDashboard] models collapsed.
///
/// The caller ([ForgeProjectPanel]) owns forge detection and provider wiring;
/// this widget only renders an [AsyncValue] and reports refresh taps.
class ProjectDashboardPanel extends StatelessWidget {
  final AsyncValue<ForgeProjectDashboard> dashboard;

  /// Refetches the whole dashboard — it is one query, so every section's
  /// refresh button means "refresh the dashboard", and their tooltips say so.
  final VoidCallback onRefresh;

  const ProjectDashboardPanel({
    super.key,
    required this.dashboard,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return dashboard.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (data) {
        // Issue rows show label chips colored by the project's label palette;
        // an issue label outside the fetched first-100 falls back to gray.
        final palette = {for (final l in data.labels) l.name: l};
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (data.warning != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DashboardWarningBanner(data.warning!),
              ),
            _header(
              context,
              'Issues',
              shown: data.issues.length,
              total: data.issuesTotal,
            ),
            data.issues.isEmpty
                ? const SectionEmpty('No open issues')
                : Column(
                    children: data.issues
                        .map((i) => _issueRow(context, i, palette))
                        .toList(),
                  ),
            const SizedBox(height: 14),
            _header(
              context,
              'Labels',
              shown: data.labels.length,
              total: data.labelsTotal,
            ),
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
            _header(
              context,
              'Milestones',
              shown: data.milestones.length,
              total: data.milestonesTotal,
            ),
            data.milestones.isEmpty
                ? const SectionEmpty('No open milestones')
                : Column(
                    children: data.milestones
                        .map((m) => _milestoneRow(context, m))
                        .toList(),
                  ),
            const SizedBox(height: 14),
            _header(
              context,
              'Releases',
              shown: data.releases.length,
              total: data.releasesTotal,
            ),
            data.releases.isEmpty
                ? const SectionEmpty('No releases')
                : Column(
                    children: data.releases
                        .map((r) => _releaseRow(context, r))
                        .toList(),
                  ),
          ],
        );
      },
    );
  }

  Widget _header(
    BuildContext context,
    String title, {
    required int shown,
    required int? total,
  }) {
    final typography = MacosTheme.of(context).typography;
    // "30 of 974" only when the forge reported a total AND rows were left
    // behind — a fully shown section needs no count, and GitLab reports no
    // total at all for milestones (null = unknown, not zero).
    final truncated = total != null && total > shown;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
      child: Row(
        children: [
          Text(
            title,
            style: typography.caption1.copyWith(fontWeight: FontWeight.bold),
          ),
          if (truncated) ...[
            const SizedBox(width: 6),
            Text(
              '$shown of $total',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
          const Spacer(),
          ToolIconButton(
            icon: CupertinoIcons.refresh,
            tooltip: 'Refresh dashboard',
            size: 15,
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }

  Widget _issueRow(
    BuildContext context,
    ForgeIssue issue,
    Map<String, ForgeLabel> palette,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${issue.id}',
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
                if (issue.author != null)
                  Text(
                    '@${issue.author}',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                if (issue.labels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 3,
                      children: issue.labels
                          .map((name) => _miniLabelChip(name, palette[name]))
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A compact chip for a label attached to an issue, colored from the
  /// project palette when the label is among the fetched ones.
  Widget _miniLabelChip(String name, ForgeLabel? label) {
    final bg = label == null
        ? const Color(0xFF888888)
        : parseLabelColor(label.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: labelTextColor(bg),
        ),
      ),
    );
  }

  Widget _labelChip(ForgeLabel label) {
    final bg = parseLabelColor(label.color);
    final chip = Container(
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
    final description = label.description;
    if (description == null || description.isEmpty) return chip;
    return MacosTooltip(message: description, child: chip);
  }

  Widget _milestoneRow(BuildContext context, ForgeMilestone milestone) {
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
          if (milestone.due != null && milestone.due!.isNotEmpty)
            Text(
              'due ${milestone.due}',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _releaseRow(BuildContext context, ForgeRelease release) {
    final typography = MacosTheme.of(context).typography;
    final date = release.publishedDate;
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
            date == null ? release.tagName : '${release.tagName} · $date',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
        ],
      ),
    );
  }
}
