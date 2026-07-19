import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/forge/forge_urls.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/show_more_row.dart';
import 'forge_selection.dart';
import 'forge_widgets.dart';
import 'issue_actions.dart';
import 'issue_create_form.dart';

/// The project sections of the Forge workspace — Issues, Milestones, Labels,
/// Releases — shared verbatim by the GitHub and GitLab panels (the providers
/// underneath are forge-neutral). Extracted from the former Project tab.

/// Stable section names for the canonical collapse store
/// (`collapsedSectionsProvider` in `../common/section_collapse.dart`).
abstract final class ForgeSections {
  static const changeRequests = 'changeRequests';
  static const ci = 'ci';
  static const issues = 'issues';
  static const milestones = 'milestones';
  static const labels = 'labels';
  static const releases = 'releases';
}

/// Case-insensitive filter: does any of [haystacks] contain [query]?
/// An empty query matches everything.
bool forgeFilterMatch(String query, Iterable<String?> haystacks) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  for (final h in haystacks) {
    if (h != null && h.toLowerCase().contains(q)) return true;
  }
  return false;
}

/// "30 of 974" when the forge reports a larger total, plain "30" when the
/// fetch is (as far as known) complete, null before anything has loaded.
String? forgeCountLabel(int? fetched, int? total) {
  if (fetched == null) return null;
  if (total != null && total > fetched) return '$fetched of $total';
  return '$fetched';
}

/// The full non-inbox left-pane list, as children for the panel's master
/// ListView, in the canonical section order: **Issues → change requests →
/// Labels → Milestones → Releases → CI**. Issues/Labels/Milestones/Releases
/// are forge-neutral and built here; the forge-specific [changeRequests]
/// (Pull Requests / Merge Requests) and [ci] (Workflow Runs / Pipelines)
/// blocks are built by the caller and slotted into positions 2 and 6. The
/// caller owns selection, filtering, and the collapse store; this renders
/// against them.
List<Widget> projectSectionChildren({
  required WidgetRef ref,
  required String repoPath,
  required Forge forge,
  required ForgeSel sel,
  required void Function(ForgeSel) onSelect,
  required String filter,
  required Set<String> collapsed,
  required void Function(String) onToggleCollapsed,
  required VoidCallback onCreateIssue,
  required List<Widget> changeRequests,
  required List<Widget> ci,
  void Function(TapUpDetails, ForgeIssue)? onIssueContextMenu,
}) {
  const collapsedCount = 10;
  final dashboard = forge == Forge.github
      ? ref.watch(githubProjectDashboardProvider(repoPath))
      : ref.watch(projectDashboardProvider(repoPath));
  void refreshDashboard() => forge == Forge.github
      ? ref.invalidate(githubProjectDashboardProvider(repoPath))
      : ref.invalidate(projectDashboardProvider(repoPath));

  final issues = ref.watch(projectIssuesProvider(repoPath));
  final milestones = ref.watch(projectMilestonesProvider(repoPath));
  final issuesFull = ref.watch(projectIssuesScopeProvider(repoPath));
  final milestonesFull = ref.watch(projectMilestonesScopeProvider(repoPath));
  final data = dashboard.value;
  final palette = {
    for (final l in data?.labels ?? const <ForgeLabel>[]) l.name: l,
  };

  final issuesCollapsed = collapsed.contains(ForgeSections.issues);
  final milestonesCollapsed = collapsed.contains(ForgeSections.milestones);
  final labelsCollapsed = collapsed.contains(ForgeSections.labels);
  final releasesCollapsed = collapsed.contains(ForgeSections.releases);

  bool issueMatches(ForgeIssue i) =>
      forgeFilterMatch(filter, [i.title, i.author, '#${i.id}', ...i.labels]);

  return [
    // Partial-data GraphQL warning, same as the create forms show: the
    // labels/releases below may be incomplete rather than genuinely absent.
    if (data?.warning != null) DashboardWarningBanner(data!.warning!),
    // 1. Issues.
    ForgeSectionHeader(
      'Issues',
      count: forgeCountLabel(issues.value?.length, data?.issuesTotal),
      collapsed: issuesCollapsed,
      onToggleCollapsed: () => onToggleCollapsed(ForgeSections.issues),
      onRefresh: () => ref.invalidate(projectIssuesProvider(repoPath)),
      onAdd: onCreateIssue,
      addTooltip: 'New issue',
    ),
    if (!issuesCollapsed) ...[
      asyncListSection(
        issues,
        filter.trim().isEmpty ? 'No open issues' : 'No matching issues',
        (i) => _issueRow(i, palette, sel, onSelect, onIssueContextMenu),
        where: issueMatches,
        skipLoadingOnReload: true,
        limit: issuesFull ? null : collapsedCount,
        overflow: (hidden) => ShowMoreRow(
          label: 'Show all issues',
          onTap: () =>
              ref.read(projectIssuesScopeProvider(repoPath).notifier).expand(),
        ),
      ),
      if (issuesFull && issues.isLoading)
        const ShowMoreRow(label: 'Loading issues…', busy: true),
      // The full fetch is still bounded (20 pages / a gh --limit) — say so
      // when the forge's own total shows we stopped short.
      if (issuesFull &&
          !issues.isLoading &&
          issues.hasValue &&
          (data?.issuesTotal ?? 0) > issues.value!.length)
        SectionEmpty(
          'Showing ${issues.value!.length} of ${data!.issuesTotal} issues',
        ),
    ],
    const SizedBox(height: 16),
    // 2. Change requests (Pull Requests / Merge Requests) — forge-specific,
    //    built by the caller.
    ...changeRequests,
    const SizedBox(height: 16),
    // 3. Labels.
    ForgeSectionHeader(
      'Labels',
      count: forgeCountLabel(data?.labels.length, data?.labelsTotal),
      collapsed: labelsCollapsed,
      onToggleCollapsed: () => onToggleCollapsed(ForgeSections.labels),
      onRefresh: refreshDashboard,
    ),
    if (!labelsCollapsed)
      // A plain Wrap bounded by this (resizable) master pane: chips flow to
      // the next row at the divider and re-lay-out as the divider is dragged.
      _dashboardSection(
        dashboard,
        (d) => _LabelsWrap(
          labels: [
            for (final l in d.labels)
              if (forgeFilterMatch(filter, [l.name])) l,
          ],
        ),
      ),
    const SizedBox(height: 16),
    // 4. Milestones.
    ForgeSectionHeader(
      'Milestones',
      count: forgeCountLabel(milestones.value?.length, data?.milestonesTotal),
      collapsed: milestonesCollapsed,
      onToggleCollapsed: () => onToggleCollapsed(ForgeSections.milestones),
      onRefresh: () => ref.invalidate(projectMilestonesProvider(repoPath)),
    ),
    if (!milestonesCollapsed) ...[
      asyncListSection(
        milestones,
        filter.trim().isEmpty ? 'No open milestones' : 'No matching milestones',
        (m) => _milestoneRow(m, sel, onSelect),
        where: (m) => forgeFilterMatch(filter, [m.title]),
        skipLoadingOnReload: true,
        limit: milestonesFull ? null : collapsedCount,
        overflow: (hidden) => ShowMoreRow(
          label: 'Show all milestones',
          onTap: () => ref
              .read(projectMilestonesScopeProvider(repoPath).notifier)
              .expand(),
        ),
      ),
      if (milestonesFull && milestones.isLoading)
        const ShowMoreRow(label: 'Loading milestones…', busy: true),
    ],
    const SizedBox(height: 16),
    // 5. Releases.
    ForgeSectionHeader(
      'Releases',
      count: forgeCountLabel(data?.releases.length, data?.releasesTotal),
      collapsed: releasesCollapsed,
      onToggleCollapsed: () => onToggleCollapsed(ForgeSections.releases),
      onRefresh: refreshDashboard,
    ),
    if (!releasesCollapsed)
      _dashboardSection(dashboard, (d) {
        final visible = [
          for (final r in d.releases)
            if (forgeFilterMatch(filter, [r.name, r.tagName])) r,
        ];
        return visible.isEmpty
            ? const SectionEmpty('No releases')
            : Column(children: [for (final r in visible) _releaseRow(r)]);
      }),
    const SizedBox(height: 16),
    // 6. CI (Workflow Runs / Pipelines) — forge-specific, built by the caller.
    ...ci,
  ];
}

/// A dashboard-backed section (Labels, Releases) with real loading/error
/// states instead of collapsing them to "empty": spinner on first load, red
/// error inline — above the last-good content when a reload failed — and
/// [body] on data. Mirrors [asyncListSection]'s error-with-value handling.
Widget _dashboardSection(
  AsyncValue<ForgeProjectDashboard> dashboard,
  Widget Function(ForgeProjectDashboard) body,
) {
  if (dashboard.hasError && dashboard.hasValue) {
    return Column(
      children: [SectionError(dashboard.error!), body(dashboard.requireValue)],
    );
  }
  return dashboard.when(
    skipLoadingOnReload: true,
    loading: () => const SectionLoading(),
    error: (err, _) => SectionError(err),
    data: body,
  );
}

Widget _issueRow(
  ForgeIssue issue,
  Map<String, ForgeLabel> palette,
  ForgeSel sel,
  void Function(ForgeSel) onSelect,
  void Function(TapUpDetails, ForgeIssue)? onContextMenu,
) => forgeIssueRow(
  issue: issue,
  palette: palette,
  sel: sel,
  onSelect: onSelect,
  onSecondaryTapUp: onContextMenu == null
      ? null
      : (d) => onContextMenu(d, issue),
);

/// An issue list row — shared by the Issues section and the Inbox (which
/// appends its pin/snooze buttons via [trailing]).
Widget forgeIssueRow({
  required ForgeIssue issue,
  required Map<String, ForgeLabel> palette,
  required ForgeSel sel,
  required void Function(ForgeSel) onSelect,
  Widget? trailing,
  GestureTapUpCallback? onSecondaryTapUp,
}) {
  final selected = switch (sel) {
    ForgeIssueSel(:final id) => id == issue.id,
    _ => false,
  };
  return ForgeListRow(
    leading: StatusBadge('#${issue.id ?? '—'}', MacosColors.systemGreenColor),
    title: issue.title,
    titleMaxLines: 2,
    caption: issue.author == null ? null : '@${issue.author}',
    chips: [
      for (final name in issue.labels) MiniLabelChip(name, palette[name]),
    ],
    trailing: trailing,
    selected: selected,
    // A row whose forge didn't report a parseable number can't drive a detail
    // fetch — leave it un-tappable rather than key the pane on a null id.
    onTap: issue.id == null ? null : () => onSelect(ForgeIssueSel(issue.id!)),
    onSecondaryTapUp: onSecondaryTapUp,
  );
}

Widget _milestoneRow(
  ForgeMilestone milestone,
  ForgeSel sel,
  void Function(ForgeSel) onSelect,
) {
  final selected = switch (sel) {
    ForgeMilestoneSel(:final id) => id == milestone.id,
    _ => false,
  };
  return ForgeListRow(
    leading: const MacosIcon(CupertinoIcons.flag, size: 14),
    title: milestone.title,
    trailingCaption: (milestone.due != null && milestone.due!.isNotEmpty)
        ? 'due ${milestone.due}'
        : null,
    selected: selected,
    onTap: milestone.id == null
        ? null
        : () => onSelect(ForgeMilestoneSel(milestone.id!)),
  );
}

Widget _releaseRow(ForgeRelease release) {
  final date = release.publishedDate;
  return ForgeListRow(
    leading: const MacosIcon(
      CupertinoIcons.tag,
      size: 14,
      color: MacosColors.systemOrangeColor,
    ),
    title: release.name.isEmpty ? release.tagName : release.name,
    trailingCaption: date == null
        ? release.tagName
        : '${release.tagName} · $date',
  );
}

/// The Labels section: a wrap of chips that reflows at the (draggable) left
/// pane's right edge. Empty → grey notice.
class _LabelsWrap extends StatelessWidget {
  final List<ForgeLabel> labels;

  const _LabelsWrap({required this.labels});

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SectionEmpty('No labels');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final l in labels) ForgeLabelChip(l)],
      ),
    );
  }
}

// ---- Detail panes -----------------------------------------------------------

/// The detail pane for the project selections (issue, milestone, new-issue
/// form), or null when [sel] isn't one of them — the caller falls through to
/// its own MR/CI details.
Widget? projectDetailFor({
  required WidgetRef ref,
  required String repoPath,
  required Forge forge,
  required ForgeSel sel,
  required String? remoteUrl,
  required VoidCallback onCloseCreate,
  required ValueChanged<bool> onDirtyChanged,
}) {
  final dashboard = forge == Forge.github
      ? ref.watch(githubProjectDashboardProvider(repoPath))
      : ref.watch(projectDashboardProvider(repoPath));
  switch (sel) {
    case ForgeCreatingIssue():
      // Milestones come from the same provider as the left-pane list (not
      // the GraphQL dashboard), so the picker always offers exactly what the
      // list shows — including group-inherited milestones on GitLab.
      final milestones =
          ref.watch(projectMilestonesProvider(repoPath)).value ??
          const <ForgeMilestone>[];
      final form = IssueCreateForm(
        repoPath: repoPath,
        labels: dashboard.value?.labels ?? const [],
        milestones: milestones,
        onClose: onCloseCreate,
        onDirtyChanged: onDirtyChanged,
      );
      // The label picker degrades to absent when the dashboard failed
      // outright — surface the failure instead of silently offering less.
      if (dashboard.hasError && !dashboard.hasValue) {
        return Column(
          children: [
            SectionError(dashboard.error!),
            Expanded(child: form),
          ],
        );
      }
      return form;
    case ForgeIssueSel(:final id):
      final detail = ref.watch(issueDetailProvider((repoPath, id)));
      final labels = dashboard.value?.labels ?? const <ForgeLabel>[];
      final palette = {for (final l in labels) l.name: l};
      return detail.when(
        loading: () => const Center(child: ProgressCircle()),
        error: (err, _) => PaneError(err),
        data: (issue) =>
            _issueDetail(issue, palette, forge, remoteUrl, repoPath),
      );
    case ForgeMilestoneSel(:final id):
      return _milestoneDetail(ref, repoPath, id, forge, remoteUrl);
    default:
      return null;
  }
}

Widget _issueDetail(
  ForgeIssue issue,
  Map<String, ForgeLabel> palette,
  Forge forge,
  String? remoteUrl,
  String repoPath,
) {
  final body = issue.body?.trim() ?? '';
  return ForgeDetailScaffold(
    leading: StatusBadge('#${issue.id ?? '—'}', MacosColors.systemGreenColor),
    title: issue.title,
    headerActions: [
      if (issue.id != null && remoteUrl != null)
        OpenInBrowserButton(forgeIssueWebUrl(remoteUrl, forge, issue.id!)),
    ],
    lines: [
      DetailLine('State', issue.state),
      if (issue.author != null) DetailLine('Author', '@${issue.author}'),
      if (issue.labels.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 4,
            runSpacing: 3,
            children: [
              for (final name in issue.labels)
                MiniLabelChip(name, palette[name]),
            ],
          ),
        ),
    ],
    body: body.isEmpty
        ? const CenteredHint('No description')
        : _detailBody(body),
    // Issues become actionable here (they were view-only before): the same
    // set as the row's right-click menu, as buttons + a "More" pulldown.
    actions: [
      IssueDetailActions(repoPath: repoPath, forge: forge, issue: issue),
    ],
  );
}

Widget _milestoneDetail(
  WidgetRef ref,
  String repoPath,
  int id,
  Forge forge,
  String? remoteUrl,
) {
  // The milestone list already carries every field the detail shows
  // (description included) — resolve from it rather than a second fetch.
  final milestones = ref.watch(projectMilestonesProvider(repoPath));
  ForgeMilestone? found;
  for (final m in milestones.value ?? const <ForgeMilestone>[]) {
    if (m.id == id) found = m;
  }
  if (found == null) {
    // Selected but not in the list: surface a failed load rather than the
    // neutral hint (which would read as "nothing selected").
    if (milestones.hasError) return PaneError(milestones.error!);
    return const CenteredHint('Select an item on the left');
  }
  final description = found.description?.trim() ?? '';
  return ForgeDetailScaffold(
    leading: const MacosIcon(CupertinoIcons.flag, size: 16),
    title: found.title,
    headerActions: [
      // Prefer the milestone's own web URL from the payload. Only fall back to
      // reconstructing from [id] on GitHub, where `id` IS the `number` the URL
      // path wants; on GitLab `id` is the global REST id (not the iid the path
      // needs), so a reconstruction would open the wrong milestone — see
      // [ForgeMilestone.webUrl].
      OpenInBrowserButton(
        found.webUrl ??
            (forge == Forge.github && remoteUrl != null
                ? forgeMilestoneWebUrl(remoteUrl, forge, id)
                : null),
      ),
    ],
    lines: [
      DetailLine('State', found.state),
      if (found.due != null && found.due!.isNotEmpty)
        DetailLine('Due', found.due!),
    ],
    body: description.isEmpty
        ? const CenteredHint('No description')
        : _detailBody(description),
  );
}

Widget _detailBody(String text) => Builder(
  builder: (context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
    child: SelectableText(text, style: MacosTheme.of(context).typography.body),
  ),
);
