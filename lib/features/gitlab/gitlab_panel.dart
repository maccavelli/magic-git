import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/forge/merge_plan.dart';
import '../../core/gitlab/models.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/branch_switch.dart';
import '../common/buttons.dart';
import '../common/context_menu.dart';
import '../common/panel_actions.dart' show kForgePanel;
import '../common/panel_shortcuts.dart';
import '../common/prompt_form_sheet.dart';
import '../common/prompt_text_sheet.dart';
import '../common/section_collapse.dart';
import '../common/show_more_row.dart';
import '../common/workspace_focus.dart';
import '../common/workspace_navigation.dart';
import '../forge/forge_inbox.dart';
import '../forge/forge_prefs.dart';
import '../forge/forge_selection.dart';
import '../forge/forge_widgets.dart';
import '../forge/forge_workspace.dart';
import '../forge/issue_actions.dart';
import '../forge/merge_options_sheet.dart';
import '../forge/merge_readiness.dart';
import '../forge/project_sections.dart';
import 'create_mr_form.dart';
import 'pipeline_jobs_view.dart';
import 'status_color.dart';

/// The GitLab half of the unified Forge workspace: one master list (Merge
/// Requests, Pipelines, Issues, Milestones, Labels, Releases — collapsible,
/// jointly filtered) beside one detail pane (MR actions + checks, pipeline
/// jobs and live logs, issue/milestone details, and the inline create forms).
/// Driven through `glab` (JSON contract) plus the forge-neutral project
/// providers.
/// A pipeline `ref` prettified for display. GitLab's "pipelines for merge
/// requests" setting runs pipelines against synthetic refs
/// (`refs/merge-requests/<iid>/head` — detached — or `/merge` — merged
/// results) that otherwise render as raw paths; decode them to `MR !<iid>`.
/// Branch refs pass through unchanged.
String prettyPipelineRef(String ref) {
  final m = RegExp(r'^refs/merge-requests/(\d+)/(head|merge)$').firstMatch(ref);
  if (m == null) return ref;
  return m.group(2) == 'merge'
      ? 'MR !${m.group(1)} (merged results)'
      : 'MR !${m.group(1)}';
}

class GitLabPanel extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether the Forge tab is the one currently showing. [AppShell] keeps
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

  /// Open MRs rendered before a "Show all" row expands the section. Bounds the
  /// eager row layout on a very active project (hundreds of open MRs) — the
  /// section is a plain Column, so every rendered row lays out whether or not
  /// it's in view. Generous enough that the cap is invisible on a normal repo.
  static const int _collapsedMrCount = 50;

  /// Set once the user taps "Show all" on the MRs section (per panel mount).
  bool _showAllMrs = false;

  ForgeSel _sel = const ForgeNothingSel();

  /// Whether an inline create form holds unsaved content (reported via
  /// onDirtyChanged). Guards row clicks and tab-away from silently
  /// destroying a draft.
  bool _draftDirty = false;

  final _filter = TextEditingController();
  String _filterQuery = '';

  /// The Inbox's type-chip filter (session-local; the Inbox/Browse mode
  /// itself is persisted via [forgeInboxModeProvider]).
  ForgeInboxKind? _inboxType;

  /// Inbox: show only change requests with no known blocker. Session-local
  /// like [_inboxType] — a triage lens, not a saved preference.
  bool _inboxUnblockedOnly = false;

  // In-flight guards for the outward-facing mutations, keyed by MR iid /
  // pipeline id: without these, the confirm-dialog-to-network-call window is
  // tappable the whole time, so a fast double-tap (or a mis-click during the
  // confirm dialog's dismiss animation) could fire two concurrent
  // approve/merge/retry calls against GitLab.
  final Set<int> _approvingMrs = {};
  final Set<int> _mergingMrs = {};
  final Set<int> _retryingPipelines = {};
  final Set<int> _checkingOutMrs = {};

  /// Re-entry guard shared by the secondary MR mutations (close / ready-draft /
  /// comment / edit), keyed by MR iid — mirrors the GitHub panel's `_busyPrs`.
  final Set<int> _busyMrs = {};

  /// The row right-click menu (one controller for the whole panel; the entries
  /// close over whichever row was clicked). Disposed with the State.
  final ContextMenuOverlay _menu = ContextMenuOverlay();

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _menu.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GitLabPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      // The panel isn't keyed by repoPath, so this same State survives a repo
      // switch — without this reset, a selection (and its in-flight guards)
      // from the old repo would leak into the new one, potentially rendering
      // an unrelated pipeline's jobs or mutating the wrong project. A draft
      // belongs to the repo it was typed for — never carry it either.
      setState(() {
        _sel = const ForgeNothingSel();
        _draftDirty = false;
        _filter.clear();
        _filterQuery = '';
      });
      _approvingMrs.clear();
      _mergingMrs.clear();
      _retryingPipelines.clear();
      _checkingOutMrs.clear();
      _busyMrs.clear();
      _lastPipelines = null;
      _pipeByRef = const {};
    } else if (oldWidget.isActive && !widget.isActive) {
      // Leaving the tab (same repo, still mounted inside AppShell's
      // IndexedStack) — clear the selection so the pipeline-jobs/job-trace
      // subtree unmounts, letting jobTraceProvider's stream actually stop
      // instead of tailing `glab ci trace` in the background indefinitely.
      // EXCEPT a dirty create draft, which stays mounted so tabbing away and
      // back doesn't destroy typed work.
      if (!isForgeCreateSel(_sel) || !_draftDirty) {
        setState(() => _sel = const ForgeNothingSel());
      }
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

  /// Switches the detail pane to [next]; when that would discard a dirty
  /// inline-create draft, asks first (safe default: keep editing).
  Future<void> _select(ForgeSel next) async {
    if (isForgeCreateSel(_sel) && _draftDirty) {
      final discard = await chooseAction<bool>(
        context,
        title: 'Discard draft?',
        message: 'The item you are composing has unsaved content.',
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
    publishLandedForgeSelection(
      ref,
      repoPath: repoPath,
      forgeLabel: 'GitLab',
      selection: next,
    );
  }

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
    // 0009 H3: apply a restored / palette-revealed forge object — selecting
    // by iid needs no list data, the detail providers fetch on their own.
    final pendingLocation = widget.isActive
        ? pendingWorkspaceLocation(ref, kForgePanel)
        : null;
    if (pendingLocation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final location = takeWorkspaceLocation(ref, kForgePanel);
        if (location == null) return;
        final iid = int.tryParse(location.identity);
        final ForgeSel? next = iid == null
            ? null
            : switch (location.kind) {
                WorkspaceFocusKind.issue => ForgeIssueSel(iid),
                WorkspaceFocusKind.request => ForgeChangeRequestSel(iid),
                WorkspaceFocusKind.pipeline => ForgeCiRunSel(iid),
                _ => null,
              };
        if (next == null) {
          markWorkspaceLocationUnavailable(ref, location);
          return;
        }
        _select(next).ignore();
      });
    }
    final mrs = ref.watch(mergeRequestsProvider(repoPath));
    final pipelines = ref.watch(pipelinesProvider(repoPath));

    // Fuse the two lists we already have: map each branch to its most recent
    // pipeline (newest-first, so the first hit per ref wins) for an MR's inline
    // CI status.
    final pipeByRef = _pipeByRefFor(pipelines.value ?? const <Pipeline>[]);

    // A branch dropped on the Forge nav item opens the inline create form
    // seeded with that branch (see drop_registry). Consumed post-frame so the
    // build stays pure.
    final seed = ref.watch(forgeCreateSeedProvider);
    if (seed != null && seed.repoPath == repoPath) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(forgeCreateSeedProvider)?.repoPath != repoPath) return;
        ref.read(forgeCreateSeedProvider.notifier).clear();
        _select(
          ForgeCreatingChangeRequest(
            seedSource: seed.branch,
            seedBase: seed.baseRef,
          ),
        );
      });
    }

    final keymap = ref.watch(keymapProvider);
    final mrIid = switch (_sel) {
      ForgeChangeRequestSel(:final id) => id,
      _ => null,
    };
    final pipelineId = switch (_sel) {
      ForgeCiRunSel(:final id) => id,
      _ => null,
    };

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'gitlab.newMr': _createMr,
      'gitlab.approve': mrIid == null ? null : () => _approve(mrIid),
      'gitlab.merge': mrIid == null ? null : () => _merge(mrIid),
      'gitlab.retry': pipelineId == null ? null : () => _retry(pipelineId),
      // Forge-agnostic ids: the same verb regardless of which host this repo
      // uses, so one menu item covers both panels.
      'forge.newIssue': _createIssue,
      'forge.cancelAutoMerge': mrIid == null
          ? null
          : () => _cancelAutoMerge(mrIid),
    };
    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: widget.isActive ? handlers : const {},
      child: ForgeRepositoryWorkspace(
        repoPath: repoPath,
        forgeLabel: 'GitLab',
        navigator: _leftPane(mrs, pipelines, pipeByRef),
        canvas: _mainPane(mrs, pipelines, pipeByRef),
        selection: _sel,
        primaryActionLabel: 'New Merge Request',
        onPrimaryAction: _createMr,
      ),
    );
  }

  // ---- Left pane -----------------------------------------------------------

  bool _mrMatches(MergeRequest mr) => forgeFilterMatch(_filterQuery, [
    mr.title,
    '!${mr.iid}',
    mr.sourceBranch,
    mr.targetBranch,
    mr.authorUsername,
    // Labels are on the row now, so they must be filterable — issues have
    // always matched theirs.
    ...mr.labels,
  ]);

  bool _pipelineFilterMatches(Pipeline p) =>
      forgeFilterMatch(_filterQuery, [p.ref, p.shortSha, p.status]);

  bool _issueMatches(ForgeIssue i) => forgeFilterMatch(_filterQuery, [
    i.title,
    i.author,
    '#${i.id}',
    ...i.labels,
  ]);

  Widget _leftPane(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
    Map<String, Pipeline> pipeByRef,
  ) {
    final fullHistory = ref.watch(pipelinesScopeProvider(repoPath));
    final mrsIncludeClosed = ref.watch(mergeRequestScopeProvider(repoPath));
    final collapsed = ref.watch(collapsedSectionsProvider);
    final mrsCollapsed = collapsed.contains(ForgeSections.changeRequests);
    final ciCollapsed = collapsed.contains(ForgeSections.ci);
    void toggle(String s) =>
        ref.read(collapsedSectionsProvider.notifier).toggle(s);
    final inboxMode = ref.watch(forgeInboxModeProvider);

    final mrMatches = _mrMatches;
    final pipelineMatches = _pipelineFilterMatches;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ForgeFilterField(
          controller: _filter,
          onChanged: (q) => setState(() => _filterQuery = q),
        ),
        ForgeModeSwitch(
          inbox: inboxMode,
          onChanged: (v) => ref.read(forgeInboxModeProvider.notifier).set(v),
        ),
        if (inboxMode)
          ..._inboxChildren(mrs, pipelines, pipeByRef)
        else
          // Canonical section order (Issues → Merge Requests → Labels →
          // Milestones → Releases → Pipelines) is composed by
          // projectSectionChildren; the two forge-specific blocks are built
          // here and slotted in.
          ...projectSectionChildren(
            ref: ref,
            repoPath: repoPath,
            forge: Forge.gitlab,
            sel: _sel,
            onSelect: (next) => _select(next),
            filter: _filterQuery,
            collapsed: collapsed,
            onToggleCollapsed: toggle,
            onCreateIssue: _createIssue,
            onIssueContextMenu: _showIssueMenu,
            changeRequests: [
              ForgeSectionHeader(
                'Merge Requests',
                count: forgeCountLabel(mrs.value?.length, null),
                collapsed: mrsCollapsed,
                onToggleCollapsed: () => toggle(ForgeSections.changeRequests),
                onRefresh: () =>
                    ref.invalidate(mergeRequestsProvider(repoPath)),
                onAdd: _createMr,
                addTooltip: 'New merge request',
              ),
              if (!mrsCollapsed)
                asyncListSection(
                  mrs,
                  _filterQuery.trim().isEmpty
                      // See the GitHub twin: once closed MRs are included,
                      // "No open merge requests" answers a different question
                      // than the one that was asked.
                      ? (mrsIncludeClosed
                            ? 'No merge requests'
                            : 'No open merge requests')
                      : 'No matching merge requests',
                  (mr) => _mrRow(mr, _headPipelineFor(mr, pipeByRef)),
                  where: mrMatches,
                  // Keep the current rows up while a refresh re-fetches, like
                  // the CI and Issues sections — don't blank the list to a
                  // spinner mid-read.
                  skipLoadingOnReload: true,
                  limit: _showAllMrs ? null : _collapsedMrCount,
                  overflow: (hidden) => ShowMoreRow(
                    label: 'Show $hidden more',
                    onTap: () => setState(() => _showAllMrs = true),
                  ),
                ),
              // Reaches closed MRs, and with them Reopen (0022 M4).
              if (!mrsCollapsed && !mrsIncludeClosed)
                ShowMoreRow(
                  label: 'Show closed merge requests',
                  onTap: () => ref
                      .read(mergeRequestScopeProvider(repoPath).notifier)
                      .includeClosed(),
                ),
              if (!mrsCollapsed && mrsIncludeClosed && mrs.isLoading)
                const ShowMoreRow(
                  label: 'Loading closed merge requests…',
                  busy: true,
                ),
            ],
            ci: [
              ForgeSectionHeader(
                'Pipelines',
                count: forgeCountLabel(pipelines.value?.length, null),
                collapsed: ciCollapsed,
                onToggleCollapsed: () => toggle(ForgeSections.ci),
                onRefresh: () => ref.invalidate(pipelinesProvider(repoPath)),
              ),
              // Newest 10 by default; "Show more" flips the scope notifier,
              // which re-fetches this same provider with the full (bounded)
              // history — skipLoadingOnReload keeps the current rows up while
              // that runs, and the busy row below is the only loading signal.
              if (!ciCollapsed) ...[
                asyncListSection(
                  pipelines,
                  _filterQuery.trim().isEmpty
                      ? 'No recent pipelines'
                      : 'No matching pipelines',
                  (p) => _pipelineRow(p),
                  where: pipelineMatches,
                  skipLoadingOnReload: true,
                  limit: fullHistory ? null : _collapsedPipelineCount,
                  overflow: (hidden) => ShowMoreRow(
                    label: 'Show all pipelines',
                    onTap: () => ref
                        .read(pipelinesScopeProvider(repoPath).notifier)
                        .expand(),
                  ),
                ),
                if (fullHistory && pipelines.isLoading)
                  const ShowMoreRow(
                    label: 'Loading pipeline history…',
                    busy: true,
                  ),
              ],
            ],
          ),
      ],
    );
  }

  /// The Inbox's triage entries: open MRs, CI runs that need attention
  /// (failed, or still moving), and open issues — in that order, jointly
  /// filtered by the shared filter field.
  List<Widget> _inboxChildren(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
    Map<String, Pipeline> pipeByRef,
  ) {
    final issues = ref.watch(projectIssuesProvider(repoPath));
    final dashboard = ref.watch(projectDashboardProvider(repoPath));
    final palette = {
      for (final l in dashboard.value?.labels ?? const <ForgeLabel>[])
        l.name: l,
    };
    // Drive off the typed status so this can't miss the non-terminal states
    // the raw `{failed, running, pending}` set dropped (created, preparing,
    // scheduled, waiting_for_resource, manual) — see [CiStatus.needsAttention].
    bool needsAttention(Pipeline p) => p.ciStatus.needsAttention;

    final entries = <ForgeInboxEntry>[
      for (final mr in mrs.value ?? const <MergeRequest>[])
        if (_mrMatches(mr))
          ForgeInboxEntry(
            itemKey: 'mr:${mr.iid}',
            kind: ForgeInboxKind.changeRequest,
            build: (extras) => _mrRow(
              mr,
              _headPipelineFor(mr, pipeByRef),
              trailingExtras: extras,
            ),
            // The app's own canonical answer, evaluated on the list row: no
            // detail fetch, so no N+1. On a list row GitLab often reports
            // `detailed_merge_status: unchecked`, so this is optimistic —
            // hence "No blockers" rather than "Ready to merge".
            noBlockers: mergePlanForGitLab(mr: mr).canMergeNow,
          ),
      for (final p in pipelines.value ?? const <Pipeline>[])
        if (needsAttention(p) && _pipelineFilterMatches(p))
          ForgeInboxEntry(
            itemKey: 'ci:${p.id}',
            kind: ForgeInboxKind.ci,
            build: (extras) => _pipelineRow(p, trailingExtras: extras),
          ),
      for (final i in issues.value ?? const <ForgeIssue>[])
        if (i.id != null && _issueMatches(i))
          ForgeInboxEntry(
            itemKey: 'issue:${i.id}',
            kind: ForgeInboxKind.issue,
            build: (extras) => forgeIssueRow(
              issue: i,
              palette: palette,
              sel: _sel,
              onSelect: (next) => _select(next),
              trailing: forgeCombineTrailing(null, extras),
              onSecondaryTapUp: (d) => _showIssueMenu(d, i),
            ),
          ),
    ];
    bool settled(AsyncValue<Object?> v) => v.hasValue || v.hasError;
    return [
      ...forgeInboxChildren(
        ref: ref,
        repoPath: repoPath,
        entries: entries,
        typeFilter: _inboxType,
        onTypeFilter: (k) => setState(() => _inboxType = k),
        unblockedOnly: _inboxUnblockedOnly,
        onUnblockedOnly: (v) => setState(() => _inboxUnblockedOnly = v),
        changeRequestLabel: 'MRs',
        listsReady: settled(mrs) && settled(pipelines) && settled(issues),
      ),
      // A failed source list must say so — an Inbox that silently omits a
      // whole category reads as "nothing needs attention".
      if (mrs.hasError) ForgeListError(mrs.error!, cli: 'glab'),
      if (pipelines.hasError) ForgeListError(pipelines.error!, cli: 'glab'),
      if (issues.hasError) ForgeListError(issues.error!, cli: 'glab'),
    ];
  }

  Widget _mrRow(
    MergeRequest mr,
    Pipeline? headPipeline, {
    List<Widget> trailingExtras = const [],
  }) {
    final selected = switch (_sel) {
      ForgeChangeRequestSel(:final id) => id == mr.iid,
      _ => false,
    };
    return ForgeListRow(
      // Keep the !iid visible even on a draft — a draft still has a number you
      // need to cite; DRAFT rides alongside it rather than replacing it.
      leading: mr.draft
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusBadge('!${mr.iid}', MacosColors.systemBlueColor),
                const SizedBox(width: 4),
                const StatusBadge('DRAFT', MacosColors.systemGrayColor),
              ],
            )
          : StatusBadge('!${mr.iid}', MacosColors.systemBlueColor),
      title: mr.title,
      titleMaxLines: 2,
      caption: mr.authorUsername != null && mr.authorUsername!.isNotEmpty
          ? '@${mr.authorUsername}  ·  ${mr.sourceBranch} → ${mr.targetBranch}'
          : '${mr.sourceBranch} → ${mr.targetBranch}',
      captionDotColor: headPipeline == null
          ? null
          : ciStatusColor(headPipeline.ciStatus),
      // GitLab exposes no approval summary on the list tier — `glab mr list`
      // takes no field selector, and MergeRequest carries no approvals data.
      // The one honest signal is `detailed_merge_status: not_approved`, so
      // this says "review needed" and never claims the converse.
      chips: [
        if (mr.detailedMergeStatus == 'not_approved')
          const ForgeReviewChip.awaiting(),
        for (final name in mr.labels) MiniLabelChip(name, _labelPalette[name]),
      ],
      trailing: forgeCombineTrailing(null, trailingExtras),
      selected: selected,
      onTap: () => _select(ForgeChangeRequestSel(mr.iid)),
      onSecondaryTapUp: (d) =>
          _menu.show(context, d.globalPosition, _mrMenu(mr), width: 240),
    );
  }

  /// Project labels by name, for coloring MR row chips. GitLab's MR payload
  /// carries only label *names*, so unlike GitHub the color has to come from
  /// the project palette; an unfetched palette yields neutral gray chips
  /// rather than none.
  Map<String, ForgeLabel> get _labelPalette => {
    for (final l
        in ref.watch(projectDashboardProvider(repoPath)).value?.labels ??
            const <ForgeLabel>[])
      l.name: l,
  };

  /// The MR row's right-click menu — grouped navigate → local → collaborate →
  /// state-change, ending in destructive Close. Merge greys out for a draft
  /// (GitLab rejects merging a draft), matching [_mergeButton]; GitLab has no
  /// per-merge rebase (project setting) so squash is the only merge variant,
  /// and no clean `glab` "request changes", so that GitHub-only action is
  /// absent here. The same actions mirror in the detail pane (primary trio as
  /// buttons, the rest under its "More" pulldown).
  List<ContextMenuEntry> _mrMenu(MergeRequest mr) {
    const draftTip =
        "Draft merge requests can't be merged — mark it ready first.";
    final policy = ref.read(repoMergePolicyProvider(repoPath)).asData?.value;
    final glPolicy = policy is GlRepoMergePolicy ? policy : null;
    final squashAlways = glPolicy?.squashAlways ?? false;
    final squashNever = glPolicy?.squashNever ?? false;
    return [
      ContextMenuItem(
        icon: CupertinoIcons.arrow_up_right_square,
        label: 'Open in browser',
        enabled: mr.webUrl.isNotEmpty,
        onTap: () => forgeOpenUrl(mr.webUrl),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.link,
        label: 'Copy link',
        enabled: mr.webUrl.isNotEmpty,
        onTap: () => forgeCopy(mr.webUrl),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.number,
        label: 'Copy !${mr.iid}',
        onTap: () => forgeCopy('!${mr.iid}'),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        // square_arrow_down: the same checkout glyph the Branches tab uses.
        icon: CupertinoIcons.square_arrow_down,
        label: 'Check out branch',
        onTap: () => _checkoutMr(mr),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.text_bubble,
        label: 'Comment…',
        onTap: () => _commentMr(mr.iid),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.checkmark_seal,
        label: 'Approve',
        onTap: () => _approve(mr.iid),
      ),
      ContextMenuItem(
        icon: mr.draft
            ? CupertinoIcons.checkmark_circle
            : CupertinoIcons.arrow_uturn_left,
        label: mr.draft ? 'Mark ready for review' : 'Convert to draft',
        onTap: () => _setMrDraft(mr.iid, draft: !mr.draft),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.pencil,
        label: 'Edit…',
        onTap: () => _editMr(mr),
      ),
      const ContextMenuDivider(),
      // Only offer what the project policy permits: `squash_option: never`
      // forbids squashing and `always` forces it, and _merge's options sheet
      // clamps the choice either way — so a forbidden entry here would be
      // silently rewritten rather than honored. The policy is read (not
      // watched): a menu is a momentary snapshot.
      if (!squashAlways)
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge',
          enabled: !mr.draft,
          disabledTooltip: draftTip,
          onTap: () => _merge(mr.iid, listMr: mr),
        ),
      if (!squashNever)
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Squash and merge',
          enabled: !mr.draft,
          disabledTooltip: draftTip,
          onTap: () => _merge(mr.iid, squash: true, listMr: mr),
        ),
      if (forgeChangeRequestIsOpen(mr.state))
        ContextMenuItem(
          icon: CupertinoIcons.xmark_circle,
          label: 'Close',
          iconColor: MacosColors.systemRedColor,
          onTap: () => _closeMr(mr.iid),
        )
      else if (forgeChangeRequestIsReopenable(mr.state))
        ContextMenuItem(
          icon: CupertinoIcons.arrow_counterclockwise,
          label: 'Reopen',
          onTap: () => _reopenMr(mr.iid),
        ),
    ];
  }

  Widget _pipelineRow(
    Pipeline pipeline, {
    List<Widget> trailingExtras = const [],
  }) {
    final selected = switch (_sel) {
      ForgeCiRunSel(:final id) => id == pipeline.id,
      _ => false,
    };
    // Retry is green; only plain refresh icons stay blue.
    final retry = pipeline.isRetryable
        ? InFlightIconButton(
            busy: _retryingPipelines.contains(pipeline.id),
            icon: CupertinoIcons.refresh_thick,
            tooltip: 'Retry pipeline',
            size: 15,
            color: MacosColors.systemGreenColor,
            onPressed: () => _retry(pipeline.id),
          )
        : null;
    return ForgeListRow(
      leading: CiDot(ciStatusColor(pipeline.ciStatus)),
      // Title + caption, structurally matching the GitHub run row (workflow /
      // branch · sha) so the two panels — and the shared Inbox — read as one
      // product. GitLab has no workflow name, so the ref leads and the sha is
      // the caption.
      title: prettyPipelineRef(pipeline.ref),
      caption: pipeline.shortSha,
      selected: selected,
      onTap: () => _select(ForgeCiRunSel(pipeline.id)),
      trailing: forgeCombineTrailing(retry, trailingExtras),
    );
  }

  // ---- Main pane -----------------------------------------------------------

  Widget _mainPane(
    AsyncValue<List<MergeRequest>> mrs,
    AsyncValue<List<Pipeline>> pipelines,
    Map<String, Pipeline> pipeByRef,
  ) {
    final remoteUrl = ref.watch(originRemoteUrlProvider(repoPath)).value;
    switch (_sel) {
      case ForgeCiRunSel(:final id):
        Pipeline? pipeline;
        for (final p in pipelines.value ?? const <Pipeline>[]) {
          if (p.id == id) pipeline = p;
        }
        return _pipelineDetail(pipeline, id);
      case ForgeChangeRequestSel(:final id):
        MergeRequest? mr;
        for (final m in mrs.value ?? const <MergeRequest>[]) {
          if (m.iid == id) mr = m;
        }
        if (mr != null) return _mrDetail(mr, pipeByRef);
        // Selected but not in the list: a failed list load should surface the
        // error, not the neutral "select something" hint (which reads as
        // "nothing is wrong") while the left-pane row still shows selected.
        if (mrs.hasError) return PaneError(mrs.error!);
        return const CenteredHint('Select an item on the left');
      case ForgeCreatingChangeRequest(:final seedSource, :final seedBase):
        return CreateMrForm(
          repoPath: repoPath,
          initialSource: seedSource,
          initialTarget: seedBase,
          onClose: () => setState(() {
            _sel = const ForgeNothingSel();
            _draftDirty = false;
          }),
          // Land on the new MR, not the neutral pane (0009 M22).
          onCreated: (iid) => _select(ForgeChangeRequestSel(iid)).ignore(),
          // No setState: dirtiness changes nothing visual until a row click
          // or tab-away consults it.
          onDirtyChanged: (dirty) => _draftDirty = dirty,
        );
      default:
        final project = projectDetailFor(
          ref: ref,
          repoPath: repoPath,
          forge: Forge.gitlab,
          sel: _sel,
          remoteUrl: remoteUrl,
          onCloseCreate: () => setState(() {
            _sel = const ForgeNothingSel();
            _draftDirty = false;
          }),
          // Land on the new issue, not the neutral pane (0009 M22).
          onIssueCreated: (iid) => _select(ForgeIssueSel(iid)).ignore(),
          onDirtyChanged: (dirty) => _draftDirty = dirty,
        );
        if (project != null) return project;
        return const CenteredHint('Select an item on the left');
    }
  }

  Widget _pipelineDetail(Pipeline? pipeline, int pipelineId) {
    return ForgeDetailScaffold(
      leading: CiDot(
        ciStatusColor(pipeline?.ciStatus ?? CiStatus.unknown),
        size: 11,
      ),
      title: pipeline == null
          ? 'Pipeline #$pipelineId'
          : 'Pipeline #$pipelineId  ·  ${pipeline.ref}',
      headerActions: [
        if (pipeline != null && pipeline.isRetryable)
          InFlightIconButton(
            busy: _retryingPipelines.contains(pipelineId),
            icon: CupertinoIcons.refresh_thick,
            tooltip: 'Retry pipeline',
            size: 16,
            color: MacosColors.systemGreenColor,
            onPressed: () => _retry(pipelineId),
          ),
        OpenInBrowserButton(pipeline?.webUrl),
      ],
      body: PipelineJobsView(repoPath: repoPath, pipelineId: pipelineId),
    );
  }

  Widget _mrDetail(MergeRequest mr, Map<String, Pipeline> pipeByRef) {
    final pipeline = _headPipelineFor(mr, pipeByRef);
    final detailAsync = ref.watch(
      mergeRequestDetailProvider((repoPath, mr.iid)),
    );
    final detail = detailAsync.asData?.value;
    final effective = detail ?? mr;
    final policy = ref.watch(repoMergePolicyProvider(repoPath)).asData?.value;
    final plan = mergePlanForGitLab(
      mr: effective,
      policy: policy is GlRepoMergePolicy ? policy : null,
    );
    final loading = detailAsync.isLoading && detail == null;

    final lines = <Widget>[
      DetailLine('Source', effective.sourceBranch),
      DetailLine('Target', effective.targetBranch),
      if (effective.authorUsername != null)
        DetailLine('Author', '@${effective.authorUsername}'),
      DetailLine('State', effective.state),
      if (effective.detailedMergeStatus != null)
        DetailLine('Merge status', effective.detailedMergeStatus!),
      if (effective.sha != null) DetailLine('Head SHA', effective.shortSha),
      if (effective.mergeWhenPipelineSucceeds)
        const DetailLine('Auto-merge', 'enabled'),
      if (effective.labels.isNotEmpty)
        DetailLine('Labels', effective.labels.join(', ')),
      if (effective.assigneeUsernames.isNotEmpty)
        DetailLine(
          'Assignees',
          effective.assigneeUsernames.map((a) => '@$a').join(', '),
        ),
    ];

    return ForgeDetailScaffold(
      leading: effective.draft
          ? const StatusBadge('DRAFT', MacosColors.systemGrayColor)
          : StatusBadge('!${effective.iid}', MacosColors.systemBlueColor),
      title: effective.title,
      headerActions: [OpenInBrowserButton(effective.webUrl)],
      lines: lines,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: MergeReadinessStrip(
              plan: plan,
              detailLoading: loading,
              onRetry: () => ref.invalidate(
                mergeRequestDetailProvider((repoPath, mr.iid)),
              ),
            ),
          ),
          // Already in the detail payload — fetched and dropped until now.
          // Bounded like the comments band so the checks pane keeps the
          // flexible space.
          if ((effective.description ?? '').trim().isNotEmpty)
            SizedBox(
              height: 120,
              child: ForgeBodyText(effective.description!.trim()),
            ),
          Expanded(child: _mrChecks(pipeline)),
          ForgeCommentsSection(
            comments: ref.watch(
              changeRequestCommentsProvider((repoPath, mr.iid)),
            ),
          ),
        ],
      ),
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
        if (plan.needsBranchUpdate)
          InFlightPushButton(
            busy: _busyMrs.contains(mr.iid),
            label: 'Rebase onto target',
            secondary: true,
            onPressed: () => _rebaseMr(effective),
          ),
        if (plan.canEnableAutoMerge)
          InFlightPushButton(
            busy: _mergingMrs.contains(mr.iid),
            label: 'Enable auto-merge',
            secondary: true,
            onPressed: () => _enableAutoMerge(effective, plan),
          ),
        if (plan.autoMergeAlreadyEnabled)
          InFlightPushButton(
            busy: _mergingMrs.contains(mr.iid),
            label: 'Cancel auto-merge',
            secondary: true,
            onPressed: () => _cancelAutoMerge(mr.iid),
          ),
        if (_mergingMrs.contains(mr.iid) &&
            !plan.canEnableAutoMerge &&
            !plan.autoMergeAlreadyEnabled)
          const ProgressCircle()
        else if (plan.canMergeNow)
          _mergeButton(effective, plan),
        _mrMorePulldown(effective),
      ],
    );
  }

  /// The detail pane's overflow for the secondary MR actions — the same set as
  /// the row's right-click menu below the primary trio, so the detail pane is a
  /// full action surface without a wall of buttons.
  Widget _mrMorePulldown(MergeRequest mr) {
    return MacosPulldownButton(
      title: 'More',
      items: [
        MacosPulldownMenuItem(
          title: const Text('Comment…'),
          onTap: () => _commentMr(mr.iid),
        ),
        MacosPulldownMenuItem(
          title: Text(mr.draft ? 'Mark ready for review' : 'Convert to draft'),
          onTap: () => _setMrDraft(mr.iid, draft: !mr.draft),
        ),
        MacosPulldownMenuItem(
          title: const Text('Edit…'),
          onTap: () => _editMr(mr),
        ),
        if (forgeChangeRequestIsOpen(mr.state))
          MacosPulldownMenuItem(
            title: const Text('Close'),
            onTap: () => _closeMr(mr.iid),
          )
        else if (forgeChangeRequestIsReopenable(mr.state))
          MacosPulldownMenuItem(
            title: const Text('Reopen'),
            onTap: () => _reopenMr(mr.iid),
          ),
      ],
    );
  }

  /// The MR detail's body: its head pipeline's jobs (checks), inline — the
  /// selected MR and its CI live on one screen instead of two selections.
  Widget _mrChecks(Pipeline? pipeline) {
    if (pipeline == null) {
      return const CenteredHint('No pipeline for this branch');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Builder(
            builder: (context) => Text(
              'Checks  ·  Pipeline #${pipeline.id}',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                fontWeight: FontWeight.bold,
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
        ),
        Expanded(
          child: PipelineJobsView(repoPath: repoPath, pipelineId: pipeline.id),
        ),
      ],
    );
  }

  /// The "Merge" action, disabled (greyed out, `onPressed: null`) with an
  /// explanatory tooltip when [mr] is a draft — GitLab's API rejects merging
  /// a draft MR outright, so this catches it client-side instead of letting
  /// the user hit a raw remote error.
  ///
  /// The alternate method only appears when the project policy actually allows
  /// it. `squash_option: always` or `never` removes a method from
  /// [MergePlan.allowedMethods] entirely, and offering the removed one made
  /// the app lie: the options sheet clamps the choice back, so picking "Merge"
  /// on a squash-always project silently squashed.
  Widget _mergeButton(MergeRequest mr, MergePlan plan) {
    final enabled = plan.canMergeNow;
    final allowSquash = plan.allowedMethods.contains(MergeMethod.squash);
    final allowMergeCommit = plan.allowedMethods.contains(
      MergeMethod.mergeCommit,
    );
    final primarySquash = plan.defaultMethod == MergeMethod.squash;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppPushButton(
          controlSize: ControlSize.large,
          onPressed: enabled
              ? () => _merge(mr.iid, squash: primarySquash, listMr: mr)
              : null,
          child: Text(primarySquash ? 'Squash and merge' : 'Merge'),
        ),
        if (enabled && allowSquash && !primarySquash) ...[
          const SizedBox(width: 4),
          MacosPulldownButton(
            icon: CupertinoIcons.chevron_down,
            items: [
              MacosPulldownMenuItem(
                title: const Text('Squash and merge'),
                onTap: () => _merge(mr.iid, squash: true, listMr: mr),
              ),
            ],
          ),
        ],
        if (enabled && allowMergeCommit && primarySquash) ...[
          const SizedBox(width: 4),
          MacosPulldownButton(
            icon: CupertinoIcons.chevron_down,
            items: [
              MacosPulldownMenuItem(
                title: const Text('Merge'),
                onTap: () => _merge(mr.iid, squash: false, listMr: mr),
              ),
            ],
          ),
        ],
      ],
    );
    if (enabled) return row;
    final tip = plan.blockedSummary.isNotEmpty
        ? plan.blockedSummary
        : "This merge request can't be merged right now.";
    return MacosTooltip(message: tip, child: row);
  }

  // ---- Actions -------------------------------------------------------------

  void _createIssue() => _select(const ForgeCreatingIssue()).ignore();

  void _createMr() {
    _select(const ForgeCreatingChangeRequest());
  }

  /// Opens an issue row's right-click menu (shared with the GitHub panel via
  /// [showIssueContextMenu]); wired to both the Browse Issues section and the
  /// Inbox's issue rows.
  void _showIssueMenu(TapUpDetails d, ForgeIssue issue) => showIssueContextMenu(
    _menu,
    context: context,
    ref: ref,
    repoPath: repoPath,
    forge: Forge.gitlab,
    details: d,
    issue: issue,
  );

  /// Refreshes every cache a change-request mutation can stale: the list,
  /// the open detail pane (which prefers detail over the list row), and its
  /// comments. One helper so a new mutation can't forget the detail again
  /// (0009 H11). [repoPath] is the caller's up-front capture — the active
  /// repo can change while a confirm/prompt is open.
  void _invalidateChangeRequest(String repoPath, int iid) {
    ref.invalidate(mergeRequestsProvider(repoPath));
    ref.invalidate(mergeRequestDetailProvider((repoPath, iid)));
    ref.invalidate(changeRequestCommentsProvider((repoPath, iid)));
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
    if (success) _invalidateChangeRequest(repoPath, iid);
  }

  Future<void> _enableAutoMerge(MergeRequest mr, MergePlan plan) async {
    if (_mergingMrs.contains(mr.iid)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Enable auto-merge',
      message:
          'Enable auto-merge for !${mr.iid}? It will merge when the pipeline '
          'succeeds (not immediately).',
      confirmLabel: 'Enable auto-merge',
    );
    if (!ok || !mounted) return;
    setState(() => _mergingMrs.add(mr.iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.enableMergeRequestAutoMerge(
        repoPath,
        mr.iid,
        sha: plan.pinHeadSha ? plan.headSha : null,
        squash: plan.defaultMethod == MergeMethod.squash,
        removeSourceBranch: plan.defaultDeleteSource,
      ),
    );
    if (!mounted) return;
    setState(() => _mergingMrs.remove(mr.iid));
    if (success) {
      ref.invalidate(mergeRequestsProvider(repoPath));
      ref.invalidate(mergeRequestDetailProvider((repoPath, mr.iid)));
    }
  }

  Future<void> _cancelAutoMerge(int iid) async {
    if (_mergingMrs.contains(iid)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Cancel auto-merge',
      message: 'Cancel auto-merge for !$iid?',
      confirmLabel: 'Cancel auto-merge',
    );
    if (!ok || !mounted) return;
    setState(() => _mergingMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.cancelMergeRequestAutoMerge(repoPath, iid),
    );
    if (!mounted) return;
    setState(() => _mergingMrs.remove(iid));
    if (success) {
      ref.invalidate(mergeRequestsProvider(repoPath));
      ref.invalidate(mergeRequestDetailProvider((repoPath, iid)));
    }
  }

  Future<void> _rebaseMr(MergeRequest mr) async {
    if (_busyMrs.contains(mr.iid)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Rebase onto target',
      message:
          'Rebase !${mr.iid} onto ${mr.targetBranch}? This rewrites the '
          'source branch history on the remote.',
      confirmLabel: 'Rebase',
    );
    if (!ok || !mounted) return;
    setState(() => _busyMrs.add(mr.iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.rebaseMergeRequest(repoPath, mr.iid),
    );
    if (!mounted) return;
    setState(() => _busyMrs.remove(mr.iid));
    if (success) {
      ref.invalidate(mergeRequestDetailProvider((repoPath, mr.iid)));
      ref.invalidate(mergeRequestsProvider(repoPath));
    }
  }

  Future<void> _merge(
    int iid, {
    bool squash = false,
    MergeRequest? listMr,
  }) async {
    if (_mergingMrs.contains(iid)) return; // already in flight
    final repoPath = this.repoPath; // see _approve

    MergeRequest detailMr =
        listMr ??
        const MergeRequest(
          iid: 0,
          title: '',
          state: 'opened',
          sourceBranch: '',
          targetBranch: '',
          webUrl: '',
          draft: false,
        );
    try {
      detailMr = await ref.read(
        mergeRequestDetailProvider((repoPath, iid)).future,
      );
    } catch (_) {
      if (listMr != null) detailMr = listMr;
    }
    if (!mounted) return;

    GlRepoMergePolicy? policy;
    final policyVal = ref.read(repoMergePolicyProvider(repoPath)).asData?.value;
    if (policyVal is GlRepoMergePolicy) policy = policyVal;

    final plan = mergePlanForGitLab(mr: detailMr, policy: policy);
    if (!plan.canMergeNow) {
      await showErrorDialog(
        context,
        plan.blockedSummary.isNotEmpty
            ? plan.blockedSummary
            : "This merge request can't be merged right now.",
      );
      return;
    }

    final initialMethod = squash ? MergeMethod.squash : MergeMethod.mergeCommit;
    final chosenMethod = plan.allowedMethods.contains(initialMethod)
        ? initialMethod
        : plan.defaultMethod;
    final shaNote = plan.pinHeadSha && plan.headSha != null
        ? ' (${plan.headSha!.substring(0, plan.headSha!.length.clamp(0, 7))})'
        : '';
    final options = await showMergeOptionsSheet(
      context,
      plan: plan,
      title: 'Merge merge request',
      summary: 'Merge !$iid$shaNote into its target branch.',
      initialMethod: chosenMethod,
    );
    if (options == null || !mounted) return;
    // Guard added after the choice so its spinner means "merging", not "dialog
    // open" — see _approve.
    setState(() => _mergingMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.mergeMergeRequest(
        repoPath,
        iid,
        squash: options.method == MergeMethod.squash,
        removeSourceBranch: options.deleteSource,
        sha: plan.pinHeadSha ? plan.headSha : null,
        squashMessage: options.subject,
        mergeCommitMessage: options.body ?? options.subject,
      ),
    );
    if (!mounted) return;
    setState(() => _mergingMrs.remove(iid));
    if (success) {
      // The MR is gone after a merge — clear the detail selection.
      setState(() => _sel = const ForgeNothingSel());
      ref.invalidate(mergeRequestsProvider(repoPath));
      ref.invalidate(mergeRequestDetailProvider((repoPath, iid)));
      if (options.deleteSource) {
        // Shared post-mutation set (refs + related) — do not hand-roll
        // individual ref invalidations (see repo_mutation_refresh_test).
        refreshAfterMutation(ref, repoPath);
      }
    }
  }

  /// Reopens a closed MR — GitLab twin of GitHubPanel._reopenPr. No confirm;
  /// reopening is not destructive.
  Future<void> _reopenMr(int iid) async {
    if (_busyMrs.contains(iid)) return;
    final repoPath = this.repoPath;
    setState(() => _busyMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.reopenMergeRequest(repoPath, iid),
    );
    if (!mounted) return;
    setState(() => _busyMrs.remove(iid));
    if (success) _invalidateChangeRequest(repoPath, iid);
  }

  Future<void> _closeMr(int iid) async {
    if (_busyMrs.contains(iid)) return;
    final repoPath = this.repoPath;
    final ok = await confirmAction(
      context,
      title: 'Close merge request',
      message: 'Close !$iid without merging? You can reopen it later.',
      confirmLabel: 'Close',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busyMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.closeMergeRequest(repoPath, iid),
    );
    if (!mounted) return;
    setState(() => _busyMrs.remove(iid));
    if (success) {
      // Closed → drops out of the open-MR list; clear the now-stale detail.
      setState(() => _sel = const ForgeNothingSel());
      ref.invalidate(mergeRequestsProvider(repoPath));
    }
  }

  Future<void> _setMrDraft(int iid, {required bool draft}) async {
    if (_busyMrs.contains(iid)) return;
    final repoPath = this.repoPath;
    setState(() => _busyMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.setMergeRequestDraft(repoPath, iid, draft: draft),
    );
    if (!mounted) return;
    setState(() => _busyMrs.remove(iid));
    if (success) _invalidateChangeRequest(repoPath, iid);
  }

  Future<void> _commentMr(int iid) async {
    if (_busyMrs.contains(iid)) return;
    final repoPath = this.repoPath;
    final body = await promptText(
      context,
      'Comment on !$iid',
      placeholder: 'Write a comment…',
      description: 'Adds a comment to the merge request on GitLab.',
      confirmLabel: 'Comment',
    );
    if (body == null || !mounted) return;
    setState(() => _busyMrs.add(iid));
    final glab = ref.read(glabServiceProvider);
    final success = await runAction(
      context,
      () => glab.commentOnMergeRequest(repoPath, iid, body),
    );
    if (!mounted) return;
    setState(() => _busyMrs.remove(iid));
    if (success) {
      ref.invalidate(changeRequestCommentsProvider((repoPath, iid)));
    }
  }

  /// Full title + description edit. Fetches the current fields first (the list
  /// query omits the description), then opens the shared multi-field
  /// [promptForm].
  Future<void> _editMr(MergeRequest mr) async {
    if (_busyMrs.contains(mr.iid)) return;
    final repoPath = this.repoPath;
    final glab = ref.read(glabServiceProvider);
    setState(() => _busyMrs.add(mr.iid));
    try {
      ({String title, String description})? current;
      final fetched = await runAction(context, () async {
        current = await glab.mergeRequestFields(repoPath, mr.iid);
      });
      if (!fetched || current == null || !mounted) return;
      final result = await promptForm(
        context,
        'Edit merge request !${mr.iid}',
        confirmLabel: 'Save',
        fields: [
          PromptField(
            key: 'title',
            label: 'Title',
            initial: current!.title,
            validate: (v) => v.isEmpty ? 'A title is required.' : null,
          ),
          PromptField(
            key: 'description',
            label: 'Description',
            initial: current!.description,
            placeholder: 'Describe the change…',
            multiline: true,
          ),
        ],
      );
      if (result == null || !mounted) return;
      final title = result['title']!;
      final description = result['description']!;
      if (title == current!.title && description == current!.description) {
        return;
      }
      final success = await runAction(
        context,
        () => glab.editMergeRequest(
          repoPath,
          mr.iid,
          title: title,
          description: description,
        ),
      );
      if (success && mounted) _invalidateChangeRequest(repoPath, mr.iid);
    } finally {
      if (mounted) setState(() => _busyMrs.remove(mr.iid));
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
