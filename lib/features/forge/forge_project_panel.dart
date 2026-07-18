import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/theme/app_theme.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/label_colors.dart';
import '../common/resizable_master_detail.dart';
import '../common/show_more_row.dart';
import 'forge_panel.dart' show UnsupportedForgeNotice;
import 'forge_widgets.dart';
import 'issue_create_form.dart';

/// The "Project" sidebar tab: a master-detail workspace over the repo's forge
/// (GitHub or GitLab), mirroring the Forge tab's layout. The left pane lists
/// open issues and milestones (paginated) plus the project's labels and
/// releases; selecting an issue or milestone opens it in the right pane, and
/// the Issues "+" opens an inline create form there.
///
/// Forge-neutral throughout: the issue/milestone list providers dispatch to
/// `gh`/`glab` internally, and labels/releases come from the shared project
/// dashboard (one GraphQL round-trip). [forgeProvider] resolves [Forge.none]
/// whenever `git remote get-url origin` fails, so the panel only ever renders
/// against a present origin.
class ForgeProjectPanel extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether the Project tab is the one currently showing. Like the other
  /// panels, kept mounted in [AppShell]'s IndexedStack — the flag lets us clear
  /// the detail selection when the tab goes offstage so its subtree unmounts.
  final bool isActive;

  const ForgeProjectPanel({
    super.key,
    required this.repoPath,
    this.isActive = true,
  });

  @override
  ConsumerState<ForgeProjectPanel> createState() => _ForgeProjectPanelState();
}

/// The right pane's current subject: nothing, a selected issue/milestone (by
/// id), or the new-issue form.
sealed class _Selection {
  const _Selection();
}

class _NothingSelected extends _Selection {
  const _NothingSelected();
}

class _IssueSelected extends _Selection {
  final int id;
  const _IssueSelected(this.id);
}

class _MilestoneSelected extends _Selection {
  final int id;
  const _MilestoneSelected(this.id);
}

class _CreatingIssue extends _Selection {
  const _CreatingIssue();
}

class _ForgeProjectPanelState extends ConsumerState<ForgeProjectPanel> {
  /// Issues/milestones shown before their "Show more" row expands the list to
  /// full (bounded) history.
  static const int _collapsedCount = 10;

  _Selection _sel = const _NothingSelected();

  /// Whether the inline new-issue form holds unsaved content (reported by
  /// [IssueCreateForm.onDirtyChanged]). Guards row clicks and tab-away from
  /// silently destroying a draft.
  bool _draftDirty = false;

  String get repoPath => widget.repoPath;

  @override
  void didUpdateWidget(ForgeProjectPanel old) {
    super.didUpdateWidget(old);
    // The panel isn't keyed by repoPath, so this State survives a repo switch;
    // and it stays mounted (though invisible) when the tab is left.
    if (old.repoPath != widget.repoPath) {
      // A draft belongs to the repo it was typed for — never carry it (or a
      // stale issue/milestone id) into the new one.
      setState(() {
        _sel = const _NothingSelected();
        _draftDirty = false;
      });
    } else if (old.isActive && !widget.isActive) {
      // Leaving the tab: clear the selection so the detail subtree unmounts
      // offstage — EXCEPT a dirty new-issue draft, which stays mounted so
      // tabbing away and back doesn't destroy typed work.
      if (_sel is! _CreatingIssue || !_draftDirty) {
        setState(() => _sel = const _NothingSelected());
      }
    }
  }

  /// Switches the detail pane to [next]; when that would discard a dirty
  /// new-issue draft, asks first (safe default: keep editing).
  Future<void> _select(_Selection next) async {
    if (_sel is _CreatingIssue && _draftDirty) {
      final discard = await chooseAction<bool>(
        context,
        title: 'Discard draft issue?',
        message: 'The new issue you are composing has unsaved content.',
        primaryLabel: 'Keep Editing',
        primaryValue: false,
        secondary: const [('Discard Draft', true)],
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      _sel = next;
      _draftDirty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final forge = ref.watch(forgeProvider(repoPath));
    return forge.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (f) => switch (f) {
        Forge.none => const NoRemoteNotice('project features'),
        Forge.unknown => const UnsupportedForgeNotice(),
        Forge.github || Forge.gitlab => _workspace(f),
      },
    );
  }

  // Labels + releases ride the per-forge project dashboard (one round-trip);
  // issues/milestones have their own paginated providers.
  AsyncValue<ForgeProjectDashboard> _dashboard(Forge forge) =>
      forge == Forge.github
      ? ref.watch(githubProjectDashboardProvider(repoPath))
      : ref.watch(projectDashboardProvider(repoPath));

  void _refreshDashboard(Forge forge) => forge == Forge.github
      ? ref.invalidate(githubProjectDashboardProvider(repoPath))
      : ref.invalidate(projectDashboardProvider(repoPath));

  Widget _workspace(Forge forge) {
    final dashboard = _dashboard(forge);
    return ResizableMasterDetail(
      paneId: PaneId.projectList,
      master: _leftPane(forge, dashboard),
      detail: _detailPane(dashboard),
    );
  }

  // ---- Left pane -----------------------------------------------------------

  Widget _leftPane(Forge forge, AsyncValue<ForgeProjectDashboard> dashboard) {
    final issues = ref.watch(projectIssuesProvider(repoPath));
    final milestones = ref.watch(projectMilestonesProvider(repoPath));
    final issuesFull = ref.watch(projectIssuesScopeProvider(repoPath));
    final milestonesFull = ref.watch(projectMilestonesScopeProvider(repoPath));
    final data = dashboard.value;
    final palette = {for (final l in data?.labels ?? const <ForgeLabel>[]) l.name: l};

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // Partial-data GraphQL warning, same as the create sheets show: the
        // labels/releases below may be incomplete rather than genuinely absent.
        if (data?.warning != null) DashboardWarningBanner(data!.warning!),
        ForgeSectionHeader(
          'Issues',
          count: _countLabel(issues.value?.length, data?.issuesTotal),
          onRefresh: () => ref.invalidate(projectIssuesProvider(repoPath)),
          onAdd: () => setState(() => _sel = const _CreatingIssue()),
          addTooltip: 'New issue',
        ),
        asyncListSection(
          issues,
          'No open issues',
          (i) => _issueRow(i, palette),
          skipLoadingOnReload: true,
          limit: issuesFull ? null : _collapsedCount,
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
        const SizedBox(height: 16),
        ForgeSectionHeader(
          'Milestones',
          count: _countLabel(milestones.value?.length, data?.milestonesTotal),
          onRefresh: () => ref.invalidate(projectMilestonesProvider(repoPath)),
        ),
        asyncListSection(
          milestones,
          'No open milestones',
          (m) => _milestoneRow(m),
          skipLoadingOnReload: true,
          limit: milestonesFull ? null : _collapsedCount,
          overflow: (hidden) => ShowMoreRow(
            label: 'Show all milestones',
            onTap: () => ref
                .read(projectMilestonesScopeProvider(repoPath).notifier)
                .expand(),
          ),
        ),
        if (milestonesFull && milestones.isLoading)
          const ShowMoreRow(label: 'Loading milestones…', busy: true),
        const SizedBox(height: 16),
        ForgeSectionHeader(
          'Labels',
          count: _countLabel(data?.labels.length, data?.labelsTotal),
          onRefresh: () => _refreshDashboard(forge),
        ),
        // A plain Wrap bounded by this (resizable) master pane: chips flow to
        // the next row at the divider and re-lay-out as the divider is dragged.
        _dashboardSection(dashboard, (d) => _LabelsWrap(labels: d.labels)),
        const SizedBox(height: 16),
        ForgeSectionHeader(
          'Releases',
          count: _countLabel(data?.releases.length, data?.releasesTotal),
          onRefresh: () => _refreshDashboard(forge),
        ),
        _dashboardSection(
          dashboard,
          (d) => d.releases.isEmpty
              ? const SectionEmpty('No releases')
              : Column(
                  children: [
                    for (final r in d.releases) _ReleaseRow(release: r),
                  ],
                ),
        ),
      ],
    );
  }

  /// "30 of 974" when the forge reports a larger total, plain "30" when the
  /// fetch is (as far as known) complete, null before anything has loaded.
  static String? _countLabel(int? fetched, int? total) {
    if (fetched == null) return null;
    if (total != null && total > fetched) return '$fetched of $total';
    return '$fetched';
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
        children: [
          SectionError(dashboard.error!),
          body(dashboard.requireValue),
        ],
      );
    }
    return dashboard.when(
      skipLoadingOnReload: true,
      loading: () => const SectionLoading(),
      error: (err, _) => SectionError(err),
      data: body,
    );
  }

  Widget _issueRow(ForgeIssue issue, Map<String, ForgeLabel> palette) {
    final selected = switch (_sel) {
      _IssueSelected(:final id) => id == issue.id,
      _ => false,
    };
    return _IssueRow(
      issue: issue,
      palette: palette,
      selected: selected,
      // A row whose forge didn't report a parseable number can't drive a detail
      // fetch — leave it un-tappable rather than key the pane on a null id.
      onTap: issue.id == null ? null : () => _select(_IssueSelected(issue.id!)),
    );
  }

  Widget _milestoneRow(ForgeMilestone milestone) {
    final selected = switch (_sel) {
      _MilestoneSelected(:final id) => id == milestone.id,
      _ => false,
    };
    return _MilestoneRow(
      milestone: milestone,
      selected: selected,
      onTap: milestone.id == null
          ? null
          : () => _select(_MilestoneSelected(milestone.id!)),
    );
  }

  // ---- Detail pane ---------------------------------------------------------

  Widget _detailPane(AsyncValue<ForgeProjectDashboard> dashboard) {
    switch (_sel) {
      case _NothingSelected():
        return const CenteredHint('Select an issue or milestone, or add one');
      case _CreatingIssue():
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
          onClose: () => setState(() {
            _sel = const _NothingSelected();
            _draftDirty = false;
          }),
          // No setState: dirtiness changes nothing visual until a row click
          // or tab-away consults it.
          onDirtyChanged: (dirty) => _draftDirty = dirty,
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
      case _IssueSelected(:final id):
        return _issueDetail(id, dashboard);
      case _MilestoneSelected(:final id):
        return _milestoneDetail(id);
    }
  }

  Widget _issueDetail(int id, AsyncValue<ForgeProjectDashboard> dashboard) {
    final detail = ref.watch(issueDetailProvider((repoPath, id)));
    final labels = dashboard.value?.labels ?? const <ForgeLabel>[];
    final palette = {for (final l in labels) l.name: l};
    return detail.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => PaneError(err),
      data: (issue) => _IssueDetailView(issue: issue, palette: palette),
    );
  }

  Widget _milestoneDetail(int id) {
    // The milestone list already carries every field the detail shows
    // (description included) — resolve from it rather than a second fetch.
    final milestones = ref.watch(projectMilestonesProvider(repoPath));
    ForgeMilestone? found;
    for (final m in milestones.value ?? const <ForgeMilestone>[]) {
      if (m.id == id) found = m;
    }
    if (found != null) return _MilestoneDetailView(milestone: found);
    // Selected but not in the list: surface a failed load rather than the
    // neutral hint (which would read as "nothing selected").
    if (milestones.hasError) return PaneError(milestones.error!);
    return const CenteredHint('Select an issue or milestone, or add one');
  }
}

// ---- Left-pane rows --------------------------------------------------------

class _IssueRow extends StatelessWidget {
  final ForgeIssue issue;
  final Map<String, ForgeLabel> palette;
  final bool selected;
  final VoidCallback? onTap;

  const _IssueRow({
    required this.issue,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusBadge('#${issue.id ?? '—'}', MacosColors.systemGreenColor),
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
                        children: [
                          for (final name in issue.labels)
                            _miniLabelChip(name, palette[name]),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MilestoneRow extends StatelessWidget {
  final ForgeMilestone milestone;
  final bool selected;
  final VoidCallback? onTap;

  const _MilestoneRow({
    required this.milestone,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
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
      ),
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  final ForgeRelease release;

  const _ReleaseRow({required this.release});

  @override
  Widget build(BuildContext context) {
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
        children: [for (final l in labels) _labelChip(l)],
      ),
    );
  }
}

// ---- Detail views ----------------------------------------------------------

class _IssueDetailView extends StatelessWidget {
  final ForgeIssue issue;
  final Map<String, ForgeLabel> palette;

  const _IssueDetailView({required this.issue, required this.palette});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final body = issue.body?.trim() ?? '';
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
                  StatusBadge(
                    '#${issue.id ?? '—'}',
                    MacosColors.systemGreenColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(issue.title, style: typography.title3)),
                ],
              ),
              const SizedBox(height: 10),
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
                        _miniLabelChip(name, palette[name]),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: body.isEmpty
              ? const CenteredHint('No description')
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: SelectableText(body, style: typography.body),
                ),
        ),
      ],
    );
  }
}

class _MilestoneDetailView extends StatelessWidget {
  final ForgeMilestone milestone;

  const _MilestoneDetailView({required this.milestone});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final description = milestone.description?.trim() ?? '';
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
                  const MacosIcon(CupertinoIcons.flag, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(milestone.title, style: typography.title3),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DetailLine('State', milestone.state),
              if (milestone.due != null && milestone.due!.isNotEmpty)
                DetailLine('Due', milestone.due!),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: description.isEmpty
              ? const CenteredHint('No description')
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: SelectableText(description, style: typography.body),
                ),
        ),
      ],
    );
  }
}

// ---- Label chips -----------------------------------------------------------

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

/// A compact chip for a label attached to an issue, colored from the project
/// palette when the label is among the fetched ones (else neutral gray).
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
