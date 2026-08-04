// hide OverlayVisibilityMode: MacosTextField takes macos_ui's own enum of
// the same name (used by the filter bar's clear button).
import 'dart:async';

import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '../../core/forge/branch_forge_status.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/display_error.dart';
import '../common/actions.dart';
import '../common/branch_switch.dart';
import '../common/busy_action.dart';
import '../common/context_menu.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import '../common/label_chip.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/prompt_text_sheet.dart';
import '../common/ref_name_validation.dart';
import '../common/resizable_master_detail.dart';
import '../common/section_collapse.dart';
import '../common/show_more_row.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../dnd/deselect.dart';
import '../dnd/drag_item.dart';
import '../forge/forge_widgets.dart' show CiDot;
import '../worktrees/add_worktree_sheet.dart';
import '../worktrees/worktree_tabs.dart';
import 'branch_dashboard_stats.dart';
import 'branch_view_model.dart';
import 'create_tag_sheet.dart';
import 'pinned_branches.dart';

/// Source-control pane: local branches (checkout/delete/create), remote-tracking
/// branches, and tags. Stashes have their own top-level namespace (StashView).
///
/// Laid out as the app's canonical master–detail (like History/Forge/Stash):
/// a left navigator of branches/tags — decluttered rows, a divergence bar and
/// status badges, right-click for the full action set — beside a detail pane
/// that carries the selected ref's context and action buttons. Rows no longer
/// each host a strip of icon buttons; the actions moved to the detail pane and
/// the context menu, so the list scans cleanly at hundreds of branches.
/// Stable names for the canonical collapse store (`collapsedSectionsProvider`
/// in `../common/section_collapse.dart`), prefixed so they never collide with
/// another tab's sections in that shared flat namespace.
abstract final class _BranchSections {
  static const pinned = 'branches.pinned';
  static const local = 'branches.local';
  static const remote = 'branches.remote';
  static const tags = 'branches.tags';
}

class BranchesView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether this panel is the currently-visible sidebar page. It stays
  /// mounted when another page is shown, so its keyboard shortcuts must go
  /// quiet rather than fire in the background.
  final bool isActive;

  const BranchesView({super.key, required this.repoPath, this.isActive = true});

  @override
  ConsumerState<BranchesView> createState() => _BranchesViewState();
}

class _BranchesViewState extends ConsumerState<BranchesView>
    with BusyActionState {
  // The selected ref, by full refname (unique across branches/remotes/tags) —
  // a click selects any row (driving the detail pane); ↑/↓ walk the LOCAL
  // branches, Enter checks the selection out, ⌘⇧M / ⌘⌫ merge / delete it.
  String? _selectedRef;

  /// Latest pure navigator snapshot. Keyboard and actions read this instead of
  /// re-scattering forge/merged/pinned/locals into mutable fields during build.
  BranchViewModel _vm = BranchViewModel.empty;

  /// Whether to nest local branches into a folder tree by their `/` prefix.
  /// Off by default — a flat list is calmer under ~15 branches — with a
  /// toolbar toggle. Grouping applies to local branches only (`feature/*`,
  /// `fix/*`); remotes stay flat.
  bool _grouped = false;

  /// Folder rows the user has collapsed (grouped mode). Keyed by the folder's
  /// full path prefix (e.g. `feature/`). Absent = expanded.
  final Set<String> _collapsedFolders = {};

  /// Stale local branches (no commit in ~3 months) collapse behind a summary
  /// row, GitHub-style — a mature repo buries the branches you actually work
  /// on under long-dead ones otherwise. The current branch is never stale.
  /// Policy lives in [kBranchStaleDays] / [isBranchStale].
  bool _showStale = false;

  /// Tags shown before the "Show more" row expands the list. Tags accrete
  /// forever (unlike branches, nothing prunes them), so a mature repo buries
  /// the section under hundreds of historical releases — the newest few are
  /// what anyone comes here for.
  static const int _collapsedTagCount = 10;
  bool _showAllTags = false;

  /// Remote branches get the same collapse: an active repo accumulates
  /// hundreds of remote-tracking refs, and unlike locals nothing here prunes
  /// them. A higher cap than tags — remotes are what the checkout-tracking
  /// flow browses.
  static const int _collapsedRemoteCount = 25;
  bool _showAllRemotes = false;

  /// Live filter over all three sections (case-insensitive substring on the
  /// short name). While non-empty it overrides both collapses — a filter IS
  /// a request to see every match.
  final _filterCtl = TextEditingController();

  final FocusNode _branchFocus = FocusNode(debugLabel: 'branch-list');
  final ScrollController _branchScroll = ScrollController();
  final Map<String, GlobalKey> _rowKeys = {};
  final _menu = ContextMenuOverlay();

  String get repoPath => widget.repoPath;

  @override
  void didUpdateWidget(BranchesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      // Same State survives a repo switch (the panel isn't keyed by repoPath)
      // — nothing from the old repo may leak into the new: not the expanded
      // tag list, not the selection (Enter would check out a same-named
      // branch in the NEW repo), not row keys for branches that don't exist
      // here, not the scroll offset.
      setState(() {
        _showAllTags = false;
        _showAllRemotes = false;
        _showStale = false;
        _selectedRef = null;
        _vm = BranchViewModel.empty;
        _collapsedFolders.clear();
        _filterCtl.clear();
      });
      _rowKeys.clear();
      if (_branchScroll.hasClients) _branchScroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _branchFocus.dispose();
    _branchScroll.dispose();
    _filterCtl.dispose();
    _menu.dispose();
    super.dispose();
  }

  GlobalKey _rowKeyFor(String refName) =>
      _rowKeys.putIfAbsent(refName, GlobalKey.new);

  /// The selected ref among ALL loaded refs (the general selection that drives
  /// the detail pane), or null.
  GitRef? _refByName(List<GitRef> all, String? name) {
    if (name == null) return null;
    for (final r in all) {
      if (r.name == name) return r;
    }
    return null;
  }

  /// The selection when it is a LOCAL branch — what the keyboard merge/delete
  /// bindings and ↑/↓ operate on. Null when nothing (or a remote/tag) is picked.
  GitRef? get _selectedLocal {
    final name = _selectedRef;
    if (name == null) return null;
    for (final b in _vm.localsOnScreen) {
      if (b.name == name) return b;
    }
    return null;
  }

  // A non-current LOCAL branch is selected — merge/delete apply (merging or
  // deleting the branch you're on is nonsensical / rejected by git).
  bool get _canActOnSelection {
    final sel = _selectedLocal;
    return sel != null && !sel.isHead;
  }

  void _select(GitRef refEntry) {
    _branchFocus.requestFocus();
    setState(() => _selectedRef = refEntry.name);
    ensureRowVisible(_rowKeyFor(refEntry.name));
  }

  void _moveSelection(int dir) {
    final navigable = _vm.navigable;
    if (navigable.isEmpty) return;
    var current = -1;
    if (_selectedRef != null) {
      for (var i = 0; i < navigable.length; i++) {
        if (navigable[i].name == _selectedRef) {
          current = i;
          break;
        }
      }
    }
    final next = stepSelection(current, dir, navigable.length);
    _select(navigable[next]);
  }

  KeyEventResult _onBranchKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || busy) {
      return KeyEventResult.ignored;
    }
    // Text interaction (the filter field) lives inside this Focus scope and key
    // events bubble leaf-to-root — without this gate, arrows/Enter typed into
    // the filter would drive the branch list. Same guard PanelShortcuts applies
    // to the ⌘-bindings.
    if (PanelShortcuts.textInteractionHasFocus()) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveSelection(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final sel = _selectedLocal;
        if (sel != null && !sel.isHead && sel.elsewhereWorktreePath == null) {
          _checkout(ref.read(gitServiceProvider), sel.shortName);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Canonical deselect — see dnd/deselect.dart for the Esc layering
        // (overlay closes first, then a live drag cancels, then this).
        return escDeselect(
          hasSelection: _selectedRef != null,
          clear: () => setState(() => _selectedRef = null),
        );
    }
    return KeyEventResult.ignored;
  }

  void _refresh() {
    // A branch op moves refs and can move HEAD — the shared helper, not a
    // loop copied here that will fall behind the app (and would forget the
    // own-mutation mark, as this copy once did).
    refreshAfterMutation(ref, repoPath);
  }

  @override
  void refreshAfterAction() => _refresh();

  /// Where [branch] is checked out, from the refs we already have loaded — no
  /// extra git call, since `%(worktreepath)` rides the existing snapshot.
  String? _worktreePathFor(String branch) {
    for (final r in _vm.allLocalBranches) {
      if (r.shortName == branch) return r.worktreePath;
    }
    return null;
  }

  /// Opens the Worktrees panel on the worktree holding this branch.
  Future<void> _switchToWorktree(String worktreePath) =>
      switchToWorktree(context, ref, worktreePath);

  /// Takes this branch into a NEW checkout, without disturbing the one you are
  /// in — the single most-requested worktree flow across every client's tracker.
  Future<void> _checkoutInNewWorktree(String branch) async {
    await showMacosSheet<void>(
      context: context,
      builder: (_) =>
          AddWorktreeSheet(repoPath: repoPath, initialCommitish: branch),
    );
    if (mounted) _refresh();
  }

  /// Checks out [ref] behind the dirty-tree guardrail (stash / carry /
  /// cancel).
  Future<void> _checkout(GitService git, String ref) async {
    await runGuarded(
      () => guardedBranchSwitch(
        context,
        this.ref,
        repoPath,
        () => git.checkout(repoPath, ref),
      ),
    );
  }

  // Manual double-tap tracking for the local rows (see [_localRowBody] for why
  // not GestureDetector.onDoubleTap). A second tap on the SAME row within the
  // window checks it out.
  String? _lastTapRef;
  DateTime? _lastTapAt;
  static const Duration _doubleTapWindow = Duration(milliseconds: 400);

  /// First tap selects (immediately); a quick second tap on the same local
  /// branch also checks it out — gated exactly like the context menu's "Check
  /// out" (HEAD is already current; a branch checked out in another worktree
  /// can't be switched to here).
  void _handleLocalTap(GitService git, GitRef branch) {
    final now = DateTime.now();
    final isDouble =
        _lastTapRef == branch.name &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < _doubleTapWindow;
    _lastTapRef = branch.name;
    _lastTapAt = now;
    _select(branch);
    if (isDouble &&
        !branch.isHead &&
        branch.elsewhereWorktreePath == null &&
        !busy) {
      _lastTapRef = null; // consume — a triple tap isn't a second checkout
      _checkout(git, branch.shortName);
    }
  }

  /// The local branch name a remote-tracking ref [remoteShortName] (e.g.
  /// `origin/feat/x`) maps to — everything after the first `/` (the remote).
  static String _remoteLocalName(String remoteShortName) =>
      remoteShortName.contains('/')
      ? remoteShortName.substring(remoteShortName.indexOf('/') + 1)
      : remoteShortName;

  /// "Check out tracking branch" on a remote row: switch to the local branch
  /// if one of that name already exists, otherwise create a NEW branch
  /// explicitly tracking this remote ref. The explicit create avoids git's
  /// DWIM checkout, which detaches HEAD onto a same-named tag or errors on a
  /// name carried by two remotes — see [GitService.checkoutTrackingBranch].
  Future<void> _checkoutRemote(GitService git, GitRef remote) async {
    final localName = _remoteLocalName(remote.shortName);
    await runGuarded(
      () => guardedBranchSwitch(
        context,
        ref,
        repoPath,
        () => _vm.localBranchNames.contains(localName)
            ? git.checkout(repoPath, localName)
            : git.checkoutTrackingBranch(
                repoPath,
                localName: localName,
                remoteRef: remote.shortName,
              ),
      ),
    );
  }

  void _copyName(String name) {
    Clipboard.setData(ClipboardData(text: name));
  }

  void _togglePin(String branch) {
    unawaited(
      setPinnedBranch(
        ref,
        repoPath,
        branch,
        pinned: !_vm.pinned.contains(branch),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final refsAsync = ref.watch(refsProvider(repoPath));
    final git = ref.read(gitServiceProvider);
    final keymap = ref.watch(keymapProvider);

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'branches.newBranch': () => _createBranchPrompt(git),
      'branches.createTag': _openCreateTagSheet,
      // Only bound with a non-current branch selected — otherwise they
      // fall through, matching the rest of the app's precondition gates.
      'branches.merge': _canActOnSelection
          ? () => _mergeBranch(git, _selectedLocal!.shortName, MergeMode.normal)
          : null,
      'branches.delete': _canActOnSelection
          ? () => _deleteBranch(git, _selectedLocal!.shortName)
          : null,
    };
    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: widget.isActive ? handlers : const {},
      child: refsAsync.when(
        loading: () => const Center(child: ProgressCircle()),
        error: (err, _) => _error(context, err),
        data: (refs) => _content(context, git, refs),
      ),
    );
  }

  Widget _content(BuildContext context, GitService git, List<GitRef> refs) {
    // Lazy forge + merged + pins — never block the list; `.value` is null until
    // (and unless) providers resolve, then badges/dashboard update.
    final forge = ref.watch(branchForgeProvider(repoPath)).value ?? const {};
    final merged =
        ref.watch(mergedBranchesProvider(repoPath)).value ?? const <String>{};
    final pinned =
        ref.watch(pinnedBranchesProvider(repoPath)).value ?? const <String>{};
    final collapsedSections = ref.watch(collapsedSectionsProvider);
    final remoteTags = ref.watch(remoteTagsProvider(repoPath)).value;
    final remotesList = ref.watch(remotesProvider(repoPath)).value;

    final vm = BranchViewModel.fromRefs(
      refs: refs,
      forge: forge,
      merged: merged,
      pinned: pinned,
      collapsedSections: collapsedSections,
      filterLower: _filterCtl.text.trim().toLowerCase(),
      showStale: _showStale,
      showAllTags: _showAllTags,
      showAllRemotes: _showAllRemotes,
      grouped: _grouped,
      collapsedFolderPrefixes: _collapsedFolders,
      remoteTags: remoteTags,
      remotesList: remotesList,
      pinnedSectionKey: _BranchSections.pinned,
      localSectionKey: _BranchSections.local,
      remoteSectionKey: _BranchSections.remote,
      tagsSectionKey: _BranchSections.tags,
      collapsedTagCount: _collapsedTagCount,
      collapsedRemoteCount: _collapsedRemoteCount,
    );
    // Single snapshot for keyboard/actions — not multiple derived fields.
    _vm = vm;

    // A flat descriptor list, not built Widgets — ListView.builder only ever
    // constructs the handful currently on-screen, so this stays cheap even for
    // a repo with hundreds of branches/tags.
    final rows = <_Row>[
      if (vm.pinnedLocals.isNotEmpty) ...[
        _PinnedHeaderRow(vm.pinnedLocals.length, collapsed: vm.pinnedCollapsed),
        if (!vm.pinnedCollapsed)
          for (final b in vm.pinnedLocals)
            _BranchRow(b, remote: false, depth: 0),
      ],
      _LocalHeaderRow(
        vm.sectionTitle(
          'Local Branches',
          vm.filteredLocals.length,
          vm.totalLocals,
        ),
        collapsed: vm.localCollapsed,
      ),
      if (!vm.localCollapsed) ...[
        ..._localRows(vm.activeLocals),
        if (vm.staleLocals.isNotEmpty && vm.filterLower.isEmpty)
          _StaleToggleRow(vm.staleLocals.length),
        if (vm.staleLocals.isNotEmpty &&
            (_showStale || vm.filterLower.isNotEmpty))
          ..._localRows(vm.staleLocals),
      ],
      _RemotesHeaderRow(
        vm.sectionTitle(
          'Remote Branches',
          vm.filteredRemotes.length,
          vm.totalRemotes,
        ),
        collapsed: vm.remoteCollapsed,
      ),
      if (!vm.remoteCollapsed) ...[
        for (final b in vm.visibleRemotes) _BranchRow(b, remote: true, depth: 0),
        if (vm.hiddenRemotes > 0) _ShowMoreRemotesRow(vm.hiddenRemotes),
      ],
      _TagsHeaderRow(
        vm.sectionTitle('Tags', vm.visibleTags.length + vm.hiddenTags, vm.allTags.length),
        collapsed: vm.tagsCollapsed,
      ),
      if (!vm.tagsCollapsed) ...[
        for (final t in vm.visibleTags) _TagRefRow(t),
        if (vm.hiddenTags > 0) _ShowMoreTagsRow(vm.hiddenTags),
      ],
    ];

    final master = Focus(
      focusNode: _branchFocus,
      onKeyEvent: _onBranchKey,
      child: Column(
        children: [
          _toolbar(git),
          Expanded(
            child: DeselectOnEmptyClick(
              onDeselect: () => setState(() => _selectedRef = null),
              child: ListView.builder(
                controller: _branchScroll,
                itemCount: rows.length,
                itemBuilder: (context, i) => _buildRow(
                  context,
                  git,
                  rows[i],
                  remoteTags: vm.remoteTags,
                  tagRemote: vm.tagRemote,
                  localOnly: vm.localOnlyTags,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return ResizableMasterDetail(
      paneId: PaneId.branchesList,
      detailFloor: 280,
      master: master,
      detail: _detailPane(
        context,
        git,
        _refByName(refs, _selectedRef),
        remoteTags: vm.remoteTags,
        tagRemote: vm.tagRemote,
        summary: vm.dashboard,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    GitService git,
    _Row row, {
    required Map<String, String>? remoteTags,
    required String? tagRemote,
    required List<String> localOnly,
  }) => switch (row) {
    _PinnedHeaderRow(:final count, :final collapsed) => _pinnedHeader(
      context,
      count,
      collapsed,
    ),
    _LocalHeaderRow(:final title, :final collapsed) => _localHeader(
      context,
      git,
      title,
      collapsed,
    ),
    _RemotesHeaderRow(:final title, :final collapsed) => _remotesHeader(
      context,
      git,
      title,
      collapsed,
    ),
    _TagsHeaderRow(:final title, :final collapsed) => _tagsHeader(
      context,
      git,
      title,
      localOnly,
      tagRemote,
      collapsed,
    ),
    _FolderRow(:final path, :final label, :final depth, :final count) =>
      _folderRow(context, path, label, depth, count),
    _BranchRow(:final branch, :final remote, :final depth) =>
      remote
          ? _remoteRow(context, git, branch)
          : _localRow(context, git, branch, depth),
    _TagRefRow(:final tag) => _tagRow(
      context,
      git,
      tag,
      _tagStatus(tag, remoteTags),
      tagRemote,
    ),
    _StaleToggleRow(:final count) => _staleToggle(count),
    _ShowMoreTagsRow(:final hidden) => ShowMoreRow(
      label: 'Show $hidden more ${hidden == 1 ? "tag" : "tags"}',
      onTap: () => setState(() => _showAllTags = true),
    ),
    _ShowMoreRemotesRow(:final hidden) => ShowMoreRow(
      label: 'Show $hidden more remote ${hidden == 1 ? "branch" : "branches"}',
      onTap: () => setState(() => _showAllRemotes = true),
    ),
  };

  // ---- The toolbar (compact filter + group toggle + fetch) -----------------

  Widget _toolbar(GitService git) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: MacosTextField(
              controller: _filterCtl,
              placeholder: 'Filter branches and tags',
              placeholderStyle: kAppPlaceholderStyle,
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
              prefix: const MacosIcon(CupertinoIcons.search, size: 14),
              clearButtonMode: OverlayVisibilityMode.editing,
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 6),
          ToolIconButton(
            icon: _grouped
                ? CupertinoIcons.list_bullet_indent
                : CupertinoIcons.list_bullet,
            tooltip: _grouped
                ? 'Grouped by folder (click for a flat list)'
                : 'Flat list (click to group by folder)',
            size: 15,
            color: _grouped ? MacosColors.systemBlueColor : null,
            onPressed: () => setState(() => _grouped = !_grouped),
          ),
          const SizedBox(width: 2),
          ToolIconButton(
            icon: CupertinoIcons.arrow_2_circlepath,
            tooltip: 'Fetch all remotes and prune deleted branches',
            size: 15,
            onPressed: busy ? null : () => _fetchPrune(git),
          ),
        ],
      ),
    );
  }

  // ---- Section headers -----------------------------------------------------

  void _toggleSection(String section) =>
      ref.read(collapsedSectionsProvider.notifier).toggle(section);

  Widget _pinnedHeader(BuildContext context, int count, bool collapsed) {
    return CollapsibleSectionHeader(
      'Pinned ($count)',
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
      collapsed: collapsed,
      onToggle: () => _toggleSection(_BranchSections.pinned),
      leading: const MacosIcon(
        CupertinoIcons.star_fill,
        size: 12,
        color: MacosColors.systemYellowColor,
      ),
    );
  }

  Widget _localHeader(
    BuildContext context,
    GitService git,
    String title,
    bool collapsed,
  ) {
    return CollapsibleSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
      collapsed: collapsed,
      onToggle: () => _toggleSection(_BranchSections.local),
      trailing: [
        ToolIconButton(
          icon: CupertinoIcons.add,
          tooltip: 'New branch…',
          size: 15,
          onPressed: busy ? null : () => _createBranchPrompt(git),
        ),
      ],
    );
  }

  /// The Remote Branches section header — the fetch-and-prune affordance also
  /// lives in the toolbar; kept here too so it sits beside its own section.
  Widget _remotesHeader(
    BuildContext context,
    GitService git,
    String title,
    bool collapsed,
  ) {
    return CollapsibleSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(16, 16, 10, 4),
      collapsed: collapsed,
      onToggle: () => _toggleSection(_BranchSections.remote),
    );
  }

  /// The Tags section header — New Tag…, plus the bulk push escape hatch when
  /// the remote listing shows local-only tags.
  Widget _tagsHeader(
    BuildContext context,
    GitService git,
    String title,
    List<String> localOnly,
    String? remote,
    bool collapsed,
  ) {
    return CollapsibleSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(16, 16, 10, 4),
      collapsed: collapsed,
      onToggle: () => _toggleSection(_BranchSections.tags),
      trailing: [
        if (localOnly.isNotEmpty && remote != null) ...[
          InlineActionButton(
            label: 'Push ${localOnly.length} to $remote',
            icon: CupertinoIcons.arrow_up,
            onPressed: busy
                ? null
                : () => _pushAllLocalOnly(git, localOnly, remote),
          ),
          const SizedBox(width: 6),
        ],
        ToolIconButton(
          icon: CupertinoIcons.tag,
          tooltip: 'New tag…',
          size: 15,
          onPressed: busy ? null : _openCreateTagSheet,
        ),
      ],
    );
  }

  Widget _staleToggle(int count) => _staleToggleRow(count);

  Widget _staleToggleRow(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 10, 4),
      child: Tappable(
        onTap: () => setState(() => _showStale = !_showStale),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            MacosIcon(
              _showStale
                  ? CupertinoIcons.chevron_down
                  : CupertinoIcons.chevron_right,
              size: 11,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 6),
            const MacosIcon(
              CupertinoIcons.clock,
              size: 13,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 6),
            Text(
              _showStale
                  ? 'Hide $count stale'
                  : '$count stale (no commit in 3 months)',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Local branch rows (flat or folder-grouped) --------------------------

  /// Flattens a set of local branches into row descriptors, either flat or
  /// folder-grouped (pure shaping in [buildLocalBranchListItems]).
  List<_Row> _localRows(List<GitRef> branches) {
    final items = buildLocalBranchListItems(
      branches: branches,
      grouped: _grouped,
      collapsedFolderPrefixes: _collapsedFolders,
    );
    return [
      for (final item in items)
        switch (item) {
          LocalBranchFolderItem(
            :final path,
            :final label,
            :final depth,
            :final count,
          ) =>
            _FolderRow(path: path, label: label, depth: depth, count: count),
          LocalBranchLeafItem(:final branch, :final depth) =>
            _BranchRow(branch, remote: false, depth: depth),
        },
    ];
  }

  Widget _folderRow(
    BuildContext context,
    String path,
    String label,
    int depth,
    int count,
  ) {
    final collapsed = _collapsedFolders.contains(path);
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        if (!_collapsedFolders.remove(path)) _collapsedFolders.add(path);
      }),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16.0 + depth * 14, 5, 10, 5),
        child: Row(
          children: [
            MacosIcon(
              collapsed
                  ? CupertinoIcons.chevron_right
                  : CupertinoIcons.chevron_down,
              size: 11,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 6),
            MacosIcon(
              collapsed ? CupertinoIcons.folder : CupertinoIcons.folder_open,
              size: 14,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: typography.body.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '$count',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localRow(
    BuildContext context,
    GitService git,
    GitRef branch,
    int depth,
  ) {
    // In grouped mode the branch shows only its leaf segment (the folder rows
    // carry the prefix); flat mode shows the full short name.
    final label = _grouped && branch.shortName.contains('/')
        ? branch.shortName.substring(branch.shortName.lastIndexOf('/') + 1)
        : branch.shortName;
    return KeyedSubtree(
      key: _rowKeyFor(branch.name),
      // The current branch is a drop target: dropping another branch on it
      // offers merge-into / rebase-onto (see [_dropOnCurrent]). Only HEAD
      // accepts, so both operations act on the checked-out branch.
      child: DragTarget<DragItem>(
        onWillAcceptWithDetails: (d) =>
            branch.isHead &&
            d.data is DragRef &&
            (d.data as DragRef).ref.name != branch.name,
        onAcceptWithDetails: (d) => _dropOnCurrent(
          git,
          source: (d.data as DragRef).ref,
          current: branch,
        ),
        builder: (context, candidate, rejected) {
          final hovering = candidate.isNotEmpty;
          final row = _localRowBody(context, git, branch, depth, label);
          if (!hovering) return row;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: _accentTint,
              border: const Border(
                left: BorderSide(color: MacosColors.systemBlueColor, width: 2),
              ),
            ),
            child: row,
          );
        },
      ),
    );
  }

  static final Color _accentTint = MacosColors.systemBlueColor.withValues(
    alpha: 0.12,
  );

  Widget _localRowBody(
    BuildContext context,
    GitService git,
    GitRef branch,
    int depth,
    String label,
  ) {
    final typography = MacosTheme.of(context).typography;
    final selected = _selectedRef == branch.name;
    final elsewhere = branch.elsewhereWorktreePath;
    return DragItemDraggable(
      item: DragRef(branch),
      immediate: true,
      onDragSelect: () => _select(branch),
      child: GestureDetector(
        // Manual double-tap detection rather than GestureDetector.onDoubleTap:
        // registering onDoubleTap makes the recognizer defer EVERY single tap
        // by the ~300ms double-tap timeout (a visible select lag, and it
        // breaks tap-to-select in tests). Here the first tap selects
        // immediately and a quick second tap on the same row also checks out.
        onTap: () => _handleLocalTap(git, branch),
        onSecondaryTapUp: (d) => _menu.show(
          context,
          d.globalPosition,
          _localMenu(git, branch),
          width: 250,
        ),
        child: Container(
          color: branch.isHead
              ? MacosColors.systemGreenColor.withValues(alpha: 0.12)
              : selected
              ? AppTheme.rowSelectionTint
              : const Color(0x00000000),
          padding: EdgeInsets.fromLTRB(16.0 + depth * 14, 7, 12, 7),
          child: Row(
            children: [
              MacosIcon(
                CupertinoIcons.arrow_branch,
                size: 15,
                color: branch.isHead
                    ? MacosColors.systemGreenColor
                    : MacosColors.systemBlueColor,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: typography.body.copyWith(
                    fontWeight: branch.isHead
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (elsewhere != null) ...[
                const SizedBox(width: 6),
                MacosTooltip(
                  message: checkedOutElsewhereMessage(elsewhere),
                  child: LabelChip(
                    elsewhere.split('/').last,
                    color: MacosColors.systemPurpleColor,
                    icon: kWorktreeIcon,
                  ),
                ),
              ],
              const Spacer(),
              ..._forgeBadges(branch),
              _divergenceCluster(context, branch),
            ],
          ),
        ),
      ),
    );
  }

  /// The trailing forge/merged signal for a local row: a grey "merged" chip
  /// (already landed in HEAD), the open PR/MR number, and a CI dot — each
  /// present only when its data is in. All degrade silently to nothing.
  List<Widget> _forgeBadges(GitRef branch) {
    final bf = _vm.forge[branch.shortName];
    final isMerged = !branch.isHead && _vm.merged.contains(branch.shortName);
    return [
      if (isMerged) ...[
        const LabelChip('merged', color: MacosColors.systemGrayColor),
        const SizedBox(width: 6),
      ],
      if (bf != null && bf.hasRequest) ...[
        MacosTooltip(
          message: bf.requestDraft
              ? 'Draft ${bf.isMr ? 'merge' : 'pull'} request ${bf.requestLabel}'
              : 'Open ${bf.isMr ? 'merge' : 'pull'} request ${bf.requestLabel}',
          child: LabelChip(
            bf.requestLabel,
            color: bf.requestDraft
                ? MacosColors.systemGrayColor
                : MacosColors.systemBlueColor,
          ),
        ),
        const SizedBox(width: 6),
      ],
      if (bf?.ci != null) ...[
        MacosTooltip(
          message: 'CI: ${_ciLabel(bf!.ci!)}',
          child: CiDot(_forgeCiColor(bf.ci!), size: 9),
        ),
        const SizedBox(width: 6),
      ],
    ];
  }

  static Color _forgeCiColor(ForgeCi c) => switch (c) {
    ForgeCi.success => MacosColors.systemGreenColor,
    ForgeCi.failure => MacosColors.systemRedColor,
    ForgeCi.running => MacosColors.systemBlueColor,
    ForgeCi.canceled || ForgeCi.skipped => MacosColors.systemGrayColor,
    ForgeCi.unknown => MacosColors.systemOrangeColor,
  };

  static String _ciLabel(ForgeCi c) => switch (c) {
    ForgeCi.success => 'passing',
    ForgeCi.failure => 'failing',
    ForgeCi.running => 'running',
    ForgeCi.canceled => 'canceled',
    ForgeCi.skipped => 'skipped',
    ForgeCi.unknown => 'unknown',
  };

  void _open(String? url) {
    if (url != null && url.isNotEmpty) {
      unawaited(launchUrl(Uri.parse(url)));
    }
  }

  /// The upstream-divergence signal: a compact split bar (behind │ ahead) plus
  /// the ↑n ↓n counts, or the `gone` marker when the upstream was deleted.
  Widget _divergenceCluster(BuildContext context, GitRef branch) {
    final typography = MacosTheme.of(context).typography;
    if (branch.upstreamGone) {
      return MacosTooltip(
        message:
            'The upstream branch was deleted (merged or removed on the '
            'remote) — this local branch is likely stale',
        child: Text(
          'gone',
          style: typography.caption1.copyWith(
            color: MacosColors.systemOrangeColor,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    if (branch.ahead == 0 && branch.behind == 0) return const SizedBox.shrink();
    return MacosTooltip(
      message:
          '${branch.ahead} commit${branch.ahead == 1 ? '' : 's'} ahead, '
          '${branch.behind} behind ${branch.upstream}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DivergenceBar(ahead: branch.ahead, behind: branch.behind),
          const SizedBox(width: 6),
          Text(
            [
              if (branch.ahead > 0) '↑${branch.ahead}',
              if (branch.behind > 0) '↓${branch.behind}',
            ].join(' '),
            style: typography.caption1.copyWith(
              color: MacosColors.systemBlueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _remoteRow(BuildContext context, GitService git, GitRef branch) {
    final typography = MacosTheme.of(context).typography;
    final selected = _selectedRef == branch.name;
    // Keyed like [_localRow] so ↑/↓ into this section can scroll the selected
    // row into view — [ensureRowVisible] no-ops without a resolvable key, so an
    // unkeyed remote/tag row moved the selection off-screen invisibly.
    return KeyedSubtree(
      key: _rowKeyFor(branch.name),
      child: Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(branch),
        onSecondaryTapUp: (d) => _menu.show(
          context,
          d.globalPosition,
          _remoteMenu(git, branch),
          width: 250,
        ),
        child: Container(
          color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Row(
            children: [
              const MacosIcon(
                CupertinoIcons.cloud,
                size: 15,
                color: MacosColors.systemGrayColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  branch.shortName,
                  style: typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tagRow(
    BuildContext context,
    GitService git,
    GitRef tag,
    _TagRemoteStatus status,
    String? remote,
  ) {
    final typography = MacosTheme.of(context).typography;
    final selected = _selectedRef == tag.name;
    // Keyed so ↑/↓ into the Tags section scrolls the selected row into view —
    // see [_remoteRow].
    return KeyedSubtree(
      key: _rowKeyFor(tag.name),
      child: Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(tag),
        onSecondaryTapUp: (d) => _menu.show(
          context,
          d.globalPosition,
          _tagMenu(git, tag, status, remote),
          width: 250,
        ),
        child: Container(
          color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Row(
            children: [
              const MacosIcon(
                CupertinoIcons.tag,
                size: 15,
                color: MacosColors.systemTealColor,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  tag.shortName,
                  style: typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (status == _TagRemoteStatus.localOnly) ...[
                const SizedBox(width: 6),
                const LabelChip(
                  'local only',
                  color: MacosColors.systemOrangeColor,
                ),
              ],
              if (status == _TagRemoteStatus.differs) ...[
                const SizedBox(width: 6),
                LabelChip(
                  'differs from $remote',
                  color: MacosColors.systemRedColor,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---- Context menus (the full action superset per ref kind) ---------------

  List<ContextMenuEntry> _localMenu(GitService git, GitRef b) {
    final elsewhere = b.elsewhereWorktreePath;
    return [
      if (!b.isHead && elsewhere == null)
        ContextMenuItem(
          icon: CupertinoIcons.square_arrow_down,
          label: 'Check out',
          onTap: () => _checkout(git, b.shortName),
        ),
      if (elsewhere != null)
        ContextMenuItem(
          icon: CupertinoIcons.square_arrow_right,
          label: 'Switch to its worktree',
          onTap: () => _switchToWorktree(elsewhere),
        ),
      ContextMenuItem(
        icon: kWorktreeIcon,
        label: 'Check out in a new worktree…',
        onTap: () => _checkoutInNewWorktree(b.shortName),
      ),
      if (!b.isHead) ...[
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge into current',
          onTap: () => _mergeBranch(git, b.shortName, MergeMode.normal),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge (no fast-forward)',
          onTap: () => _mergeBranch(git, b.shortName, MergeMode.noFf),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge (fast-forward only)',
          onTap: () => _mergeBranch(git, b.shortName, MergeMode.ffOnly),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Squash merge',
          onTap: () => _mergeBranch(git, b.shortName, MergeMode.squash),
        ),
      ],
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_up_arrow_down,
        label: 'Set upstream…',
        onTap: () => _setUpstream(git, b),
      ),
      if (b.upstream != null)
        ContextMenuItem(
          icon: CupertinoIcons.arrow_up_arrow_down,
          label: 'Unset upstream',
          onTap: () => _unsetUpstream(git, b.shortName),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.pencil,
        label: 'Rename…',
        onTap: () => _renameBranch(git, b.shortName),
      ),
      ContextMenuItem(
        icon: _vm.pinned.contains(b.shortName)
            ? CupertinoIcons.star_slash
            : CupertinoIcons.star,
        label: _vm.pinned.contains(b.shortName) ? 'Unpin' : 'Pin to top',
        onTap: () => _togglePin(b.shortName),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_doc,
        label: 'Copy name',
        onTap: () => _copyName(b.shortName),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete branch',
        iconColor: MacosColors.systemRedColor,
        enabled: !b.isHead && elsewhere == null,
        disabledTooltip: b.isHead
            ? "Can't delete the branch you're on"
            : 'Checked out in the worktree "${elsewhere?.split('/').last}" '
                  '— remove that worktree first',
        onTap: () => _deleteBranch(git, b.shortName),
      ),
    ];
  }

  List<ContextMenuEntry> _remoteMenu(GitService git, GitRef b) {
    return [
      ContextMenuItem(
        icon: CupertinoIcons.square_arrow_down,
        label: 'Check out tracking branch',
        onTap: () => _checkoutRemote(git, b),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_doc,
        label: 'Copy name',
        onTap: () => _copyName(b.shortName),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete branch on the remote',
        iconColor: MacosColors.systemRedColor,
        onTap: () => _deleteRemoteBranch(git, b.shortName),
      ),
    ];
  }

  List<ContextMenuEntry> _tagMenu(
    GitService git,
    GitRef tag,
    _TagRemoteStatus status,
    String? remote,
  ) {
    return [
      if (remote != null)
        ContextMenuItem(
          icon: CupertinoIcons.cloud_upload,
          label: status == _TagRemoteStatus.inSync
              ? 'Already on $remote'
              : 'Push tag to $remote',
          enabled: status != _TagRemoteStatus.inSync,
          onTap: () => _pushTag(git, tag.shortName, remote),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_doc,
        label: 'Copy name',
        onTap: () => _copyName(tag.shortName),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete tag',
        iconColor: MacosColors.systemRedColor,
        onTap: () => _deleteTag(git, tag, status, remote),
      ),
    ];
  }

  // ---- Detail pane ---------------------------------------------------------

  Widget _detailPane(
    BuildContext context,
    GitService git,
    GitRef? sel, {
    required Map<String, String>? remoteTags,
    required String? tagRemote,
    required BranchDashboardStats summary,
  }) {
    if (sel == null) return _dashboard(context, git, summary);
    if (sel.isTag) {
      return _tagDetail(
        context,
        git,
        sel,
        _tagStatus(sel, remoteTags),
        tagRemote,
      );
    }
    if (sel.isRemote) return _remoteDetail(context, git, sel);
    return _localDetail(context, git, sel);
  }

  /// The empty-state review dashboard: a at-a-glance summary of the repo's
  /// branches with one-click cleanup — the "what needs attention" landing view
  /// (Tower's Branches Review / GitHub's branches overview), shown whenever
  /// nothing is selected.
  Widget _dashboard(
    BuildContext context,
    GitService git,
    BranchDashboardStats s,
  ) {
    final typography = MacosTheme.of(context).typography;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Branches',
            style: typography.title2.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Select a branch or tag for its details and actions — or right-'
            'click any row.',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _statChip('Local', s.local, MacosColors.systemBlueColor),
              _statChip('Active', s.active, MacosColors.systemGreenColor),
              _statChip('Stale', s.stale, MacosColors.systemOrangeColor),
              _statChip('Pinned', s.pinned, MacosColors.systemYellowColor),
              _statChip('Remote', s.remote, MacosColors.systemGrayColor),
              _statChip('Tags', s.tags, MacosColors.systemTealColor),
            ],
          ),
          if (s.mergedDeletable.isNotEmpty) ...[
            const SizedBox(height: 18),
            _calloutBox(
              context,
              MacosColors.systemGrayColor,
              CupertinoIcons.checkmark_seal,
              '${s.mergedDeletable.length} branch'
              '${s.mergedDeletable.length == 1 ? '' : 'es'} already merged into '
              'the current branch — safe to clean up.',
            ),
            const SizedBox(height: 10),
            _detailButton(
              'Delete ${s.mergedDeletable.length} merged…',
              CupertinoIcons.trash,
              busy ? null : () => _deleteMergedBranches(git, s.mergedDeletable),
              tone: InlineActionTone.destructive,
            ),
          ],
          if (s.stale > 0) ...[
            const SizedBox(height: 18),
            Text(
              '${s.stale} stale branch${s.stale == 1 ? '' : 'es'} '
              '(no commit in 3 months) — collapsed under the Local section.',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statChip(String label, int count, Color color) {
    return Builder(
      builder: (context) {
        final typography = MacosTheme.of(context).typography;
        return Container(
          width: 96,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$count',
                style: typography.title2.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              Text(
                label,
                style: typography.caption2.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Bulk cleanup: delete every local branch already merged into HEAD (plain
  /// `-d`, so unmerged work is never at risk). Branches git refuses (e.g. held
  /// by a worktree) are skipped, not aborted.
  Future<void> _deleteMergedBranches(GitService git, List<String> names) async {
    if (busy || names.isEmpty) return;
    final listing = names.length <= 10 ? '\n\n${names.join(', ')}' : '';
    final ok = await confirmAction(
      context,
      title: 'Delete merged branches',
      message:
          'Delete ${names.length} branch${names.length == 1 ? '' : 'es'} '
          'already merged into the current branch?$listing',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runGuarded(() async {
      for (final n in names) {
        try {
          await git.deleteBranch(repoPath, n);
        } catch (_) {
          // Skip a branch git won't delete (checked out elsewhere, etc.).
        }
      }
    });
  }

  Widget _detailScaffold({
    required IconData icon,
    required Color iconColor,
    required String name,
    required List<Widget> info,
    required List<Widget> actions,
    Widget? callout,
    List<Widget> below = const [],
  }) {
    return Builder(
      builder: (context) {
        final typography = MacosTheme.of(context).typography;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MacosIcon(icon, size: 18, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: typography.title3.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...info,
              if (callout != null) ...[const SizedBox(height: 14), callout],
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
              ...below,
            ],
          ),
        );
      },
    );
  }

  /// The single-branch linear view: a preview of the most recent commits
  /// reachable from [revision] — GitKraken's missing "just this branch" list.
  /// Renders nothing until (and unless) [branchCommitsProvider] resolves.
  Widget _branchCommits(BuildContext context, String revision) {
    final commits =
        ref.watch(branchCommitsProvider((repoPath, revision))).value ??
        const [];
    if (commits.isEmpty) return const SizedBox.shrink();
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text(
          'RECENT COMMITS',
          style: typography.caption2.copyWith(
            color: MacosColors.systemGrayColor,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        for (final c in commits)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(top: 5, right: 9),
                  decoration: BoxDecoration(
                    color: c.isMerge
                        ? MacosColors.systemGrayColor
                        : MacosColors.systemBlueColor,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Text(
                    c.subject,
                    style: typography.caption1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  c.shortHash,
                  style: typography.caption2.copyWith(
                    color: MacosColors.systemGrayColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  relativeIsoLabel(c.date),
                  style: typography.caption2.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }



  Widget _infoLine(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: typography.caption1.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _localDetail(BuildContext context, GitService git, GitRef b) {
    final elsewhere = b.elsewhereWorktreePath;
    final bf = _vm.forge[b.shortName];
    final isMerged = !b.isHead && _vm.merged.contains(b.shortName);
    final info = <Widget>[
      _infoLine(context, 'Tip commit', b.subject.isEmpty ? '—' : b.subject),
      if (b.creatorDate != null)
        _infoLine(context, 'Updated', relativeEpochLabel(b.creatorDate)),
      _infoLine(
        context,
        'Upstream',
        b.upstreamGone
            ? '${b.upstream ?? '—'} (gone)'
            : b.upstream ?? 'not tracking',
        valueColor: b.upstreamGone ? MacosColors.systemOrangeColor : null,
      ),
      if (b.ahead > 0 || b.behind > 0)
        _infoLine(
          context,
          'Divergence',
          '${b.ahead} ahead · ${b.behind} behind',
        ),
      if (bf != null && bf.hasRequest)
        _infoLine(
          context,
          bf.isMr ? 'Merge request' : 'Pull request',
          '${bf.requestLabel}${bf.requestDraft ? ' (draft)' : ''}'
          '${(bf.requestTitle ?? '').isEmpty ? '' : ' — ${bf.requestTitle}'}',
        ),
      if (bf?.ci != null)
        _infoLine(
          context,
          'CI',
          _ciLabel(bf!.ci!),
          valueColor: _forgeCiColor(bf.ci!),
        ),
      if (elsewhere != null)
        _infoLine(
          context,
          'Worktree',
          elsewhere,
          valueColor: MacosColors.systemPurpleColor,
        ),
    ];
    // "Next action" hint. An open request wins; then merged/gone cleanup; then
    // the forge-free divergence hint.
    Widget? callout;
    if (isMerged) {
      callout = _calloutBox(
        context,
        MacosColors.systemGrayColor,
        CupertinoIcons.checkmark_seal,
        'Already merged into the current branch — safe to delete.',
      );
    } else if (b.upstreamGone) {
      callout = _calloutBox(
        context,
        MacosColors.systemOrangeColor,
        CupertinoIcons.exclamationmark_triangle,
        'Its upstream is gone — likely merged and pruned. Safe to delete once '
        'you\'ve confirmed the work landed.',
      );
    } else if (bf != null && bf.hasRequest) {
      callout = _calloutBox(
        context,
        MacosColors.systemBlueColor,
        CupertinoIcons.arrow_up_right_square,
        '${bf.isMr ? 'Merge' : 'Pull'} request ${bf.requestLabel} is open'
        '${bf.requestDraft ? ' (draft)' : ''}.',
      );
    } else if (!b.isHead && b.ahead > 0 && b.behind == 0) {
      callout = _calloutBox(
        context,
        MacosColors.systemGreenColor,
        CupertinoIcons.arrow_up_circle,
        '${b.ahead} commit${b.ahead == 1 ? '' : 's'} ahead, none behind — '
        'ready to merge into the current branch'
        '${b.upstream == null ? '' : ', or open a pull request'}.',
      );
    }
    final actions = <Widget>[
      if (bf != null && bf.hasRequest)
        _detailButton(
          'Open ${bf.requestLabel}',
          CupertinoIcons.arrow_up_right_square,
          () => _open(bf.requestUrl),
        ),
      if (!b.isHead && elsewhere == null)
        _detailButton(
          'Check out',
          CupertinoIcons.square_arrow_down,
          busy ? null : () => _checkout(git, b.shortName),
        ),
      if (elsewhere != null)
        _detailButton(
          'Switch to worktree',
          CupertinoIcons.square_arrow_right,
          busy ? null : () => _switchToWorktree(elsewhere),
        ),
      _detailButton(
        'New worktree…',
        kWorktreeIcon,
        busy ? null : () => _checkoutInNewWorktree(b.shortName),
      ),
      if (!b.isHead)
        _detailButton(
          'Merge into current',
          CupertinoIcons.arrow_merge,
          busy ? null : () => _mergeBranch(git, b.shortName, MergeMode.normal),
        ),
      _detailButton(
        'Set upstream…',
        CupertinoIcons.arrow_up_arrow_down,
        busy ? null : () => _setUpstream(git, b),
      ),
      _detailButton(
        'Rename…',
        CupertinoIcons.pencil,
        busy ? null : () => _renameBranch(git, b.shortName),
      ),
      _detailButton(
        _vm.pinned.contains(b.shortName) ? 'Unpin' : 'Pin to top',
        _vm.pinned.contains(b.shortName)
            ? CupertinoIcons.star_slash
            : CupertinoIcons.star,
        () => _togglePin(b.shortName),
      ),
      if (!b.isHead && elsewhere == null)
        _detailButton(
          'Delete',
          CupertinoIcons.trash,
          busy ? null : () => _deleteBranch(git, b.shortName),
          tone: InlineActionTone.destructive,
        ),
    ];
    return _detailScaffold(
      icon: CupertinoIcons.arrow_branch,
      iconColor: b.isHead
          ? MacosColors.systemGreenColor
          : MacosColors.systemBlueColor,
      name: b.shortName,
      info: [Builder(builder: (c) => Column(children: info))],
      actions: actions,
      callout: callout,
      below: [_branchCommits(context, b.shortName)],
    );
  }

  Widget _remoteDetail(BuildContext context, GitService git, GitRef b) {
    final localName = _remoteLocalName(b.shortName);
    return _detailScaffold(
      icon: CupertinoIcons.cloud,
      iconColor: MacosColors.systemGrayColor,
      name: b.shortName,
      info: [
        Builder(
          builder: (c) => Column(
            children: [
              _infoLine(c, 'Tip commit', b.subject.isEmpty ? '—' : b.subject),
              _infoLine(c, 'Tracking as', localName),
            ],
          ),
        ),
      ],
      actions: [
        _detailButton(
          'Check out tracking branch',
          CupertinoIcons.square_arrow_down,
          busy ? null : () => _checkoutRemote(git, b),
        ),
        _detailButton(
          'Delete on remote',
          CupertinoIcons.trash,
          busy ? null : () => _deleteRemoteBranch(git, b.shortName),
          tone: InlineActionTone.destructive,
        ),
      ],
      below: [_branchCommits(context, b.shortName)],
    );
  }

  Widget _tagDetail(
    BuildContext context,
    GitService git,
    GitRef tag,
    _TagRemoteStatus status,
    String? remote,
  ) {
    return _detailScaffold(
      icon: CupertinoIcons.tag,
      iconColor: MacosColors.systemTealColor,
      name: tag.shortName,
      info: [
        Builder(
          builder: (c) => Column(
            children: [
              _infoLine(
                c,
                'Tip commit',
                tag.subject.isEmpty ? '—' : tag.subject,
              ),
              if (tag.creatorDate != null)
                _infoLine(c, 'Created', relativeEpochLabel(tag.creatorDate)),
              _infoLine(
                c,
                'Remote',
                switch (status) {
                  _TagRemoteStatus.inSync => 'in sync with $remote',
                  _TagRemoteStatus.localOnly => 'local only',
                  _TagRemoteStatus.differs => 'differs from $remote',
                  _TagRemoteStatus.unknown => 'unknown',
                },
                valueColor: switch (status) {
                  _TagRemoteStatus.localOnly => MacosColors.systemOrangeColor,
                  _TagRemoteStatus.differs => MacosColors.systemRedColor,
                  _ => null,
                },
              ),
            ],
          ),
        ),
      ],
      actions: [
        if (remote != null)
          _detailButton(
            status == _TagRemoteStatus.inSync
                ? 'Already on $remote'
                : 'Push to $remote',
            CupertinoIcons.cloud_upload,
            busy || status == _TagRemoteStatus.inSync
                ? null
                : () => _pushTag(git, tag.shortName, remote),
          ),
        _detailButton(
          'Delete tag',
          CupertinoIcons.trash,
          busy ? null : () => _deleteTag(git, tag, status, remote),
          tone: InlineActionTone.destructive,
        ),
      ],
    );
  }

  Widget _detailButton(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    InlineActionTone tone = InlineActionTone.normal,
  }) => InlineActionButton(
    label: label,
    icon: icon,
    onPressed: onPressed,
    tone: tone,
  );

  Widget _calloutBox(
    BuildContext context,
    Color color,
    IconData icon,
    String text,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MacosIcon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: typography.caption1)),
        ],
      ),
    );
  }

  // ---- Actions (unchanged from the flat view: same GitService calls, same
  //      confirms and escalations — only the UI that triggers them moved) ----

  /// Prompts for a new branch name (ref-format validated inline) and creates
  /// it. Replaces the old always-present full-width create bar.
  Future<void> _createBranchPrompt(GitService git) async {
    if (busy) return;
    final name = await promptText(
      context,
      'New branch',
      placeholder: 'branch name',
      description: 'Creates a branch at the current HEAD and checks it out.',
      confirmLabel: 'Create',
      validate: refNameProblem,
    );
    if (name == null || name.isEmpty || !mounted) return;
    await runGuarded(() => git.createBranch(repoPath, name));
  }

  Future<void> _deleteBranch(GitService git, String name) async {
    if (busy) return;
    final ok = await confirmAction(
      context,
      title: 'Delete branch',
      message: 'Delete local branch "$name"?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runGuarded(() async {
      try {
        await git.deleteBranch(repoPath, name);
      } on GitException catch (e) {
        if (!mounted) rethrow;
        if (e.branchHeldByWorktree) {
          final worktree = _worktreePathFor(name);
          if (worktree == null) {
            // We can't locate the worktree to offer removing it — tell the
            // user to do it themselves rather than showing an action button
            // that would silently no-op.
            if (mounted) {
              await showErrorDialog(
                context,
                'This branch is checked out in another worktree. Remove that '
                'worktree first, then delete the branch.',
              );
            }
            return;
          }
          // Warn upfront when deleting will ALSO cost unmerged commits, so the
          // whole decision is made once with full information rather than the
          // branch-force question ambushing the user after the worktree is
          // already gone. `_vm.merged` may be stale/absent — the post-removal
          // not-fully-merged escalation below is the backstop.
          final unmerged = !_vm.merged.contains(name);
          final removeToo = await confirmAction(
            context,
            title: 'Branch is checked out in a worktree',
            message:
                'This branch is checked out in the worktree at\n$worktree\n\n'
                'Git cannot delete a branch that is checked out. Remove the '
                'worktree as well?'
                '${unmerged ? '\n\nNote: "$name" has commits not merged into '
                          'the current branch, so deleting it may discard those '
                          'commits too.' : ''}',
            confirmLabel: 'Remove Worktree and Delete',
            destructive: true,
          );
          if (!removeToo || !mounted) return;
          // Non-force removal FIRST: a worktree with uncommitted changes then
          // prompts specifically (see [_removeWorktreeSafely]) instead of the
          // old unconditional `force: true` discarding that work silently.
          if (!await _removeWorktreeSafely(git, worktree) || !mounted) return;
          try {
            await git.deleteBranch(repoPath, name);
          } on GitException catch (e2) {
            if (!mounted || !e2.branchNotFullyMerged) rethrow;
            await _confirmForceDelete(git, name);
          }
          return;
        }
        if (!e.branchNotFullyMerged) rethrow;
        await _confirmForceDelete(git, name);
      }
    });
  }

  /// Removes [worktree], escalating to `--force` ONLY behind a specifically
  /// worded confirm when git refuses because the worktree has uncommitted
  /// changes (or is locked). Returns whether it was removed; false means the
  /// user declined the destructive escalation and their work is intact.
  ///
  /// The plain `git worktree remove` honors git's dirty guard — the whole
  /// point: the old caller passed `force: true` unconditionally, so a dirty
  /// worktree's uncommitted edits were discarded with no warning (and, if the
  /// user then cancelled the branch force-delete, for nothing).
  Future<bool> _removeWorktreeSafely(GitService git, String worktree) async {
    try {
      await git.removeWorktree(repoPath, worktree);
      return true;
    } on GitException catch (e) {
      if (!mounted || (!e.worktreeDirty && !e.worktreeLocked)) rethrow;
      final discard = await confirmAction(
        context,
        title: e.worktreeLocked
            ? 'Worktree is locked'
            : 'Worktree has uncommitted changes',
        message: e.worktreeLocked
            ? 'The worktree at\n$worktree\nis locked. Remove it anyway?'
            : 'The worktree at\n$worktree\nhas uncommitted changes that will '
                  'be permanently lost. Remove it and discard them?',
        confirmLabel: e.worktreeLocked ? 'Remove' : 'Discard and Remove',
        destructive: true,
      );
      if (!discard || !mounted) return false;
      await git.removeWorktree(
        repoPath,
        worktree,
        force: true,
        locked: e.worktreeLocked,
      );
      return true;
    }
  }

  /// The not-fully-merged escalation — one confirm, one force retry, shared
  /// by the direct delete path and the after-worktree-removal retry so the
  /// data-loss decision is worded (and gated) in exactly one place.
  Future<void> _confirmForceDelete(GitService git, String name) async {
    final force = await confirmAction(
      context,
      title: 'Branch not fully merged',
      message:
          '"$name" has commits not merged into the current branch. '
          "Force-deleting will permanently lose them unless they're "
          'reachable from elsewhere (another branch, a tag, or a stash). '
          'Force delete anyway?',
      confirmLabel: 'Force Delete',
    );
    if (!force || !mounted) return;
    await git.deleteBranch(repoPath, name, force: true);
  }

  Future<void> _mergeBranch(
    GitService git,
    String branch,
    MergeMode mode,
  ) async {
    if (busy) return;
    final message = switch (mode) {
      MergeMode.normal => 'Merge "$branch" into the current branch?',
      MergeMode.noFf =>
        'Merge "$branch" into the current branch, always creating a merge '
            'commit (--no-ff)?',
      MergeMode.ffOnly =>
        'Fast-forward the current branch to "$branch" (--ff-only)?',
      MergeMode.squash =>
        'Squash-merge "$branch": stage its combined changes without '
            'committing?',
    };
    final ok = await confirmAction(
      context,
      title: 'Merge branch',
      message: message,
      confirmLabel: 'Merge',
    );
    if (!ok) return;
    await _runMerge(git, branch, mode);
  }

  /// The merge itself, past its confirmation — shared by the menu/detail merge
  /// (which confirms via [confirmAction]) and the drag-drop merge (which
  /// confirms via its own Merge-vs-Rebase choice).
  Future<void> _runMerge(GitService git, String branch, MergeMode mode) async {
    final label = [
      'git merge',
      if (mode == MergeMode.noFf) '--no-ff',
      if (mode == MergeMode.ffOnly) '--ff-only',
      if (mode == MergeMode.squash) '--squash',
      branch,
    ].join(' ');
    await runLogged(
      label,
      (log) async =>
          log.logResult(label, await git.merge(repoPath, branch, mode: mode)),
    );
  }

  /// `git rebase <onto>` — rebases the CURRENT branch onto [onto]. A conflict
  /// throws and lands in the app-wide pending-op flow (Continue/Abort in the
  /// repo panel), same as any other rebase.
  Future<void> _runRebaseOnto(GitService git, String onto) async {
    final label = 'git rebase $onto';
    await runLogged(
      label,
      (log) async => log.logResult(label, await git.rebaseOnto(repoPath, onto)),
      dock: true,
    );
  }

  /// A branch was dropped onto the current branch's row: offer to merge it in
  /// or rebase the current branch onto it. Restricted to a drop onto the
  /// current branch so both operations act on HEAD — no surprise checkout, and
  /// the choice dialog IS the confirmation. Merge conflicts / rebase conflicts
  /// fall through to the existing pending-op handling.
  Future<void> _dropOnCurrent(
    GitService git, {
    required GitRef source,
    required GitRef current,
  }) async {
    if (busy || !source.isLocalBranch || source.name == current.name) return;
    final op = await chooseAction<_DropOp>(
      context,
      title: 'Combine with ${current.shortName}',
      message: 'Bring "${source.shortName}" and the current branch together.',
      primaryLabel: 'Merge "${source.shortName}" into "${current.shortName}"',
      primaryValue: _DropOp.merge,
      secondary: [
        (
          'Rebase "${current.shortName}" onto "${source.shortName}"',
          _DropOp.rebase,
        ),
        ('Cancel', _DropOp.cancel),
      ],
    );
    if (op == null || op == _DropOp.cancel || !mounted) return;
    final g = ref.read(gitServiceProvider);
    if (op == _DropOp.merge) {
      await _runMerge(g, source.shortName, MergeMode.normal);
    } else {
      await _runRebaseOnto(g, source.shortName);
    }
  }

  /// Opens the Create Tag sheet (annotated toggle, message, push-after-create).
  Future<void> _openCreateTagSheet() async {
    final created = await showMacosSheet<bool>(
      context: context,
      builder: (_) => CreateTagSheet(repoPath: repoPath),
    );
    if (created == true && mounted) _refresh();
  }

  /// Where a local tag stands relative to the remote's copy.
  static _TagRemoteStatus _tagStatus(
    GitRef tag,
    Map<String, String>? remoteTags,
  ) {
    if (remoteTags == null) return _TagRemoteStatus.unknown;
    final remoteOid = remoteTags[tag.shortName];
    if (remoteOid == null) return _TagRemoteStatus.localOnly;
    return remoteOid == tag.oid
        ? _TagRemoteStatus.inSync
        : _TagRemoteStatus.differs;
  }

  /// Pushes one tag — through the output log, like every network op.
  Future<void> _pushTag(GitService git, String name, String remote) async {
    final label = 'git push $remote refs/tags/$name';
    await runLogged(label, (log) async {
      log.logResult(label, await git.pushTag(repoPath, name, remote: remote));
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  /// Deletes a tag; when the remote also has it, a three-way choice — the
  /// local delete stays journaled (⌘Z restores it), the remote one is not.
  Future<void> _deleteTag(
    GitService git,
    GitRef tag,
    _TagRemoteStatus status,
    String? remote,
  ) async {
    final name = tag.shortName;
    final knownOnRemote =
        status == _TagRemoteStatus.inSync || status == _TagRemoteStatus.differs;
    if (knownOnRemote && remote != null) {
      final choice = await chooseAction<_TagDeleteScope>(
        context,
        title: 'Delete tag',
        message:
            'Tag "$name" also exists on "$remote". Deleting it there removes '
            'it for everyone who uses the remote — the local delete is '
            'undoable (⌘Z), the remote one is not.',
        primaryLabel: 'Delete Local Only',
        primaryValue: _TagDeleteScope.local,
        secondary: [
          ('Delete Local and on $remote', _TagDeleteScope.both),
          ('Cancel', _TagDeleteScope.cancel),
        ],
      );
      if (choice == null || choice == _TagDeleteScope.cancel || !mounted) {
        return;
      }
      final deletedLocally = await runGuarded(
        () => git.deleteTag(repoPath, name),
      );
      if (deletedLocally && choice == _TagDeleteScope.both && mounted) {
        await runLogged('git push --delete', (log) async {
          log.logResult(
            'git push --delete $remote refs/tags/$name',
            await git.deleteRemoteTag(repoPath, remote, name),
          );
        }, dock: true);
        if (mounted) refreshRemoteTags(ref, repoPath);
      }
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Delete tag',
      message: 'Delete local tag "$name"?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok && mounted) {
      await runGuarded(() => git.deleteTag(repoPath, name));
    }
  }

  Future<void> _pushAllLocalOnly(
    GitService git,
    List<String> names,
    String remote,
  ) async {
    final listing = names.length <= 8 ? '\n\n${names.join(', ')}' : '';
    final ok = await confirmAction(
      context,
      title: 'Push tags',
      message:
          'Push ${names.length} tag(s) that exist only locally to '
          '"$remote"?$listing',
      confirmLabel: 'Push',
    );
    if (!ok || !mounted) return;
    await runLogged('git push tags', (log) async {
      log.logResult(
        'git push $remote ${names.map((n) => 'refs/tags/$n').join(' ')}',
        await git.pushTags(repoPath, names, remote: remote),
      );
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  /// Deletes a branch on its remote (`git push --delete`). Destructive and
  /// NOT undoable from here.
  Future<void> _deleteRemoteBranch(GitService git, String shortName) async {
    final slash = shortName.indexOf('/');
    if (slash <= 0) return;
    final remote = shortName.substring(0, slash);
    final branch = shortName.substring(slash + 1);
    final ok = await confirmAction(
      context,
      title: 'Delete remote branch',
      message:
          'Delete "$branch" on "$remote"? This removes it for everyone who '
          'uses the remote, and it cannot be undone from here.',
      confirmLabel: 'Delete on Remote',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runLogged('git push --delete', (log) async {
      log.logResult(
        'git push --delete $remote $branch',
        await git.deleteRemoteBranch(repoPath, remote, branch),
      );
    }, dock: true);
  }

  /// Points a branch's upstream at a remote-tracking branch.
  Future<void> _setUpstream(GitService git, GitRef branch) async {
    if (busy) return;
    final name = branch.shortName;
    final target = await promptText(
      context,
      'Set upstream',
      placeholder: 'origin/$name',
      initial: branch.upstream ?? 'origin/$name',
      description:
          'The remote-tracking branch (remote/branch) that pull, push, and '
          'the ahead/behind badges follow.',
      confirmLabel: 'Set Upstream',
      validate: refNameProblem,
    );
    if (target == null || !mounted) return;
    await runGuarded(() => git.setUpstream(repoPath, name, target));
  }

  Future<void> _unsetUpstream(GitService git, String name) async {
    if (busy) return;
    await runGuarded(() => git.unsetUpstream(repoPath, name));
  }

  /// One-click `git fetch --all --prune`.
  Future<void> _fetchPrune(GitService git) async {
    await runLogged('git fetch --all --prune', (log) async {
      log.logResult('git fetch --all --prune', await git.fetch(repoPath));
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  /// Renames a local branch via the shared name prompt.
  Future<void> _renameBranch(GitService git, String oldName) async {
    final newName = await promptText(
      context,
      'Rename branch',
      placeholder: 'new name',
      initial: oldName,
      validate: refNameProblem,
    );
    if (newName == null || newName == oldName || !mounted) return;
    await runGuarded(() => git.renameBranch(repoPath, oldName, newName));
    // Follow the rename in the selection so the detail pane and ↑/↓ keep
    // pointing at the row the user was just acting on.
    if (mounted && _selectedRef == 'refs/heads/$oldName') {
      setState(() => _selectedRef = 'refs/heads/$newName');
    }
  }

  Widget _error(BuildContext context, Object err) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      // displayError strips the raw `GitException: … (exit 128)` debug wrapper
      // to the human-facing message, matching every Forge error surface.
      displayError(err),
      style: MacosTheme.of(
        context,
      ).typography.body.copyWith(color: MacosColors.systemRedColor),
    ),
  );
}

/// The behind │ ahead divergence glyph: a small split bar whose left half fills
/// with the behind count (red) and right half with the ahead count (green),
/// each capped so a wildly-diverged branch doesn't blow out the row.
class _DivergenceBar extends StatelessWidget {
  final int ahead;
  final int behind;
  const _DivergenceBar({required this.ahead, required this.behind});

  static const double _width = 54;
  static const double _half = 27;

  double _seg(int n) {
    if (n == 0) return 0;
    // 2px minimum so a single commit still reads; scale to the half by ~20.
    return (2 + (_half - 3) * (n.clamp(0, 20) / 20)).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      height: 12,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: _seg(behind),
                height: 8,
                decoration: BoxDecoration(
                  color: MacosColors.systemRedColor.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, height: 12, color: MacosColors.separatorColor),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: _seg(ahead),
                height: 8,
                decoration: BoxDecoration(
                  color: MacosColors.systemGreenColor.withValues(alpha: 0.9),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row descriptor for the navigator's `ListView.builder` — cheap data, not a
/// built [Widget], so only the visible rows are ever constructed.
sealed class _Row {
  const _Row();
}

class _PinnedHeaderRow extends _Row {
  final int count;
  final bool collapsed;
  const _PinnedHeaderRow(this.count, {required this.collapsed});
}

class _LocalHeaderRow extends _Row {
  final String title;
  final bool collapsed;
  const _LocalHeaderRow(this.title, {required this.collapsed});
}

class _RemotesHeaderRow extends _Row {
  final String title;
  final bool collapsed;
  const _RemotesHeaderRow(this.title, {required this.collapsed});
}

class _TagsHeaderRow extends _Row {
  final String title;
  final bool collapsed;
  const _TagsHeaderRow(this.title, {required this.collapsed});
}

class _FolderRow extends _Row {
  final String path;
  final String label;
  final int depth;
  final int count;
  const _FolderRow({
    required this.path,
    required this.label,
    required this.depth,
    required this.count,
  });
}

class _BranchRow extends _Row {
  final GitRef branch;
  final bool remote;
  final int depth;
  const _BranchRow(this.branch, {required this.remote, required this.depth});
}

class _TagRefRow extends _Row {
  final GitRef tag;
  const _TagRefRow(this.tag);
}

class _StaleToggleRow extends _Row {
  final int count;
  const _StaleToggleRow(this.count);
}

class _ShowMoreTagsRow extends _Row {
  final int hidden;
  const _ShowMoreTagsRow(this.hidden);
}

class _ShowMoreRemotesRow extends _Row {
  final int hidden;
  const _ShowMoreRemotesRow(this.hidden);
}

/// Where a local tag stands relative to the remote's copy.
enum _TagRemoteStatus {
  /// No listing available (remote unreachable, or none configured).
  unknown,

  /// The tag exists locally but not on the remote — the attention state this
  /// whole feature exists for.
  localOnly,

  /// Same name, same (unpeeled) oid — pushing again would be a no-op.
  inSync,

  /// Same name, different oid — a push would be rejected by the remote.
  differs,
}

/// The three-way outcome of deleting a tag that also exists on the remote.
enum _TagDeleteScope { local, both, cancel }

/// The choice offered when a branch is dropped onto the current branch's row.
enum _DropOp { merge, rebase, cancel }
