import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/theme/app_theme.dart';
import '../common/actions.dart';
import '../common/branch_switch.dart';
import '../common/busy_action.dart';
import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/label_chip.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/prompt_text_sheet.dart';
import '../common/show_more_row.dart';
import '../common/tool_icon_button.dart';
import '../dnd/deselect.dart';
import '../dnd/drag_item.dart';
import '../worktrees/add_worktree_sheet.dart';
import '../worktrees/worktree_tabs.dart';
import 'create_tag_sheet.dart';

/// Source-control pane: local branches (checkout/delete/create), remote-tracking
/// branches, and tags. Stashes have their own top-level namespace (StashView).
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
  final _newBranch = TextEditingController();
  final _newBranchFocus = FocusNode();

  // Keyboard navigation of the local-branch list: a click selects a branch
  // (highlight) and focuses the list; ↑/↓ then walk the selection, Enter checks
  // it out, and ⌘⇧M / ⌘⌫ merge / delete it. Checkout also has its own row
  // button so the mouse-only path doesn't depend on the keyboard.
  String? _selectedBranch;
  List<GitRef> _locals = const [];

  /// Tags shown before the "Show more" row expands the list. Tags accrete
  /// forever (unlike branches, nothing prunes them), so a mature repo buries
  /// the section under hundreds of historical releases — the newest few are
  /// what anyone comes here for.
  static const int _collapsedTagCount = 10;
  bool _showAllTags = false;
  final FocusNode _branchFocus = FocusNode(debugLabel: 'branch-list');
  final ScrollController _branchScroll = ScrollController();
  final Map<String, GlobalKey> _branchRowKeys = {};

  String get repoPath => widget.repoPath;

  @override
  void didUpdateWidget(BranchesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      // Same State survives a repo switch (the panel isn't keyed by repoPath)
      // — an expanded tag list from the old repo shouldn't leak into the new.
      setState(() => _showAllTags = false);
    }
  }

  @override
  void dispose() {
    _newBranch.dispose();
    _newBranchFocus.dispose();
    _branchFocus.dispose();
    _branchScroll.dispose();
    super.dispose();
  }

  GlobalKey _branchRowKeyFor(String shortName) =>
      _branchRowKeys.putIfAbsent(shortName, GlobalKey.new);

  GitRef? get _selectedRef {
    final name = _selectedBranch;
    if (name == null) return null;
    for (final b in _locals) {
      if (b.shortName == name) return b;
    }
    return null;
  }

  // A non-current branch is selected — merge/delete apply (merging or deleting
  // the branch you're on is nonsensical / rejected by git).
  bool get _canActOnSelection {
    final sel = _selectedRef;
    return sel != null && !sel.isHead;
  }

  void _selectBranch(String shortName) {
    _branchFocus.requestFocus();
    setState(() => _selectedBranch = shortName);
    ensureRowVisible(_branchRowKeyFor(shortName));
  }

  void _moveBranchSelection(int dir) {
    if (_locals.isEmpty) return;
    var current = -1;
    if (_selectedBranch != null) {
      for (var i = 0; i < _locals.length; i++) {
        if (_locals[i].shortName == _selectedBranch) {
          current = i;
          break;
        }
      }
    }
    final next = stepSelection(current, dir, _locals.length);
    _selectBranch(_locals[next].shortName);
  }

  KeyEventResult _onBranchKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || busy) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveBranchSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveBranchSelection(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final sel = _selectedRef;
        if (sel != null && !sel.isHead) {
          _checkout(ref.read(gitServiceProvider), sel.shortName);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Canonical deselect — see dnd/deselect.dart for the Esc layering
        // (overlay closes first, then a live drag cancels, then this).
        return escDeselect(
          hasSelection: _selectedBranch != null,
          clear: () => setState(() => _selectedBranch = null),
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
    for (final r in _locals) {
      if (r.shortName == branch) return r.worktreePath;
    }
    return null;
  }

  /// Opens the Worktrees panel on the worktree holding this branch.
  ///
  /// Offered instead of Checkout when a branch is checked out elsewhere: git
  /// refuses to check it out twice, and going to where it already lives is what
  /// the user actually wants. Delegates to the shared [switchToWorktree].
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
  /// cancel). [runGuarded]'s always-refresh matters here: guardedBranchSwitch's
  /// stash step can succeed while the checkout itself then fails, leaving
  /// partial state (stash created, branch unchanged) that refsProvider/
  /// statusProvider need to reflect rather than staying stale.
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

  @override
  Widget build(BuildContext context) {
    final refsAsync = ref.watch(refsProvider(repoPath));
    final git = ref.read(gitServiceProvider);
    final keymap = ref.watch(keymapProvider);

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'branches.newBranch': () => _newBranchFocus.requestFocus(),
      'branches.createTag': _openCreateTagSheet,
      // Only bound with a non-current branch selected — otherwise they
      // fall through, matching the rest of the app's precondition gates.
      'branches.merge': _canActOnSelection
          ? () => _mergeBranch(git, _selectedBranch!, MergeMode.normal)
          : null,
      'branches.delete': _canActOnSelection
          ? () => _deleteBranch(git, _selectedBranch!)
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
        data: (refs) {
          final locals = refs.where((r) => r.isLocalBranch).toList();
          final remotes = refs.where((r) => r.isRemote).toList();
          final tags = refs.where((r) => r.isTag).toList();
          // The remote's tag listing (null = unknown: unreachable, or no
          // remote) and the remote the tag actions target — the same
          // origin-preferred choice remoteTagsProvider makes. While the
          // remotes list is still loading, fall back to 'origin' so the push
          // buttons don't blink out; a CONFIRMED empty list hides them.
          final remoteTags = ref.watch(remoteTagsProvider(repoPath)).value;
          final remotesList = ref.watch(remotesProvider(repoPath)).value;
          final String? tagRemote = remotesList == null
              ? 'origin'
              : remotesList.isEmpty
              ? null
              : defaultRemote(remotesList);
          final localOnlyTags = remoteTags == null
              ? const <String>[]
              : [
                  for (final t in tags)
                    if (!remoteTags.containsKey(t.shortName)) t.shortName,
                ];
          // Newest first: for-each-ref's default order is refname-ascending,
          // which for release tags reads oldest-to-newest — backwards from
          // what anyone scanning for the latest release wants. Dateless refs
          // (a pre-2.7 remote git) sink to the end; name breaks ties (and
          // keeps the order deterministic — List.sort isn't stable).
          tags.sort((a, b) {
            final cmp = (b.creatorDate ?? -1).compareTo(a.creatorDate ?? -1);
            return cmp != 0 ? cmp : a.shortName.compareTo(b.shortName);
          });
          final visibleTags = _showAllTags
              ? tags
              : tags.take(_collapsedTagCount).toList();
          final hiddenTags = tags.length - visibleTags.length;
          // Cache for the arrow-key handler (which runs outside build).
          _locals = locals;
          // A flat descriptor list, not built Widgets — ListView.builder below
          // only ever constructs the handful currently on-screen, so this stays
          // cheap even for a repo with hundreds of branches/tags.
          final rows = <_Row>[
            const _CreateBranchRow(),
            _HeaderRow('Local Branches (${locals.length})'),
            for (final b in locals) _BranchRow(b, remote: false),
            _HeaderRow('Remote Branches (${remotes.length})'),
            for (final b in remotes) _BranchRow(b, remote: true),
            _TagsHeaderRow(tags.length),
            const _CreateTagRow(),
            for (final t in visibleTags) _TagRefRow(t),
            if (hiddenTags > 0) _ShowMoreTagsRow(hiddenTags),
          ];
          return Focus(
            focusNode: _branchFocus,
            onKeyEvent: _onBranchKey,
            child: DeselectOnEmptyClick(
              onDeselect: () => setState(() => _selectedBranch = null),
              child: ListView.builder(
              controller: _branchScroll,
              itemCount: rows.length,
              itemBuilder: (context, i) => switch (rows[i]) {
                _CreateBranchRow() => _createBranchBar(git),
                _CreateTagRow() => _createTagBar(),
                _HeaderRow(:final title) => _sectionHeader(context, title),
                _TagsHeaderRow(:final count) => _tagsHeader(
                  context,
                  git,
                  count,
                  localOnlyTags,
                  tagRemote,
                ),
                _BranchRow(:final branch, :final remote) =>
                  remote
                      ? _remoteRow(context, git, branch)
                      : _localRow(context, git, branch),
                _TagRefRow(:final tag) => _tagRow(
                  context,
                  git,
                  tag,
                  _tagStatus(tag, remoteTags),
                  tagRemote,
                ),
                _ShowMoreTagsRow(:final hidden) => ShowMoreRow(
                  label: 'Show $hidden more ${hidden == 1 ? "tag" : "tags"}',
                  onTap: () => setState(() => _showAllTags = true),
                ),
              },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _createBranchBar(GitService git) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: MacosTextField(
              controller: _newBranch,
              focusNode: _newBranchFocus,
              placeholder: 'New branch name',
              placeholderStyle: kAppPlaceholderStyle,
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
            ),
          ),
          const SizedBox(width: 8),
          // Listens to the controller directly instead of `setState`-ing the
          // whole view on every keystroke — that used to re-run the entire
          // branch/tag list rebuild just to toggle this one button.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _newBranch,
            builder: (context, value, _) => AppPushButton(
              controlSize: ControlSize.large,
              onPressed: value.text.trim().isEmpty || busy
                  ? null
                  : () async {
                      final name = value.text.trim();
                      await runGuarded(() => git.createBranch(repoPath, name));
                      // Guard: _run spans an SSH/local round-trip, during which
                      // a tab switch or disconnect can dispose this State (and
                      // _newBranch); clearing a disposed controller throws.
                      if (mounted) _newBranch.clear();
                    },
              child: const Text('Create'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _localRow(BuildContext context, GitService git, GitRef branch) {
    final typography = MacosTheme.of(context).typography;
    final selected = _selectedBranch == branch.shortName;
    // Checked out in ANOTHER worktree — see [GitRef.isCheckedOutElsewhere].
    final elsewhere = branch.elsewhereWorktreePath;
    // A single click selects (so ↑/↓, Enter, ⌘⇧M and ⌘⌫ target it); checkout is
    // its own button (below) and Enter, so selecting can't accidentally switch
    // branches. The current branch keeps its green tint.
    return KeyedSubtree(
      key: _branchRowKeyFor(branch.shortName),
      // Immediate (mouse-first) drag — see DragItemDraggable: drop a branch on
      // the Worktrees tab to spin up a worktree, or on Forge for a PR/MR.
      child: DragItemDraggable(
        item: DragRef(branch),
        immediate: true,
        // Picking a row up selects it — the same path a click takes, so the
        // selection bar moves to the dragged branch (canonical engine contract).
        onDragSelect: () => _selectBranch(branch.shortName),
        child: GestureDetector(
          onTap: () => _selectBranch(branch.shortName),
          child: Container(
            color: branch.isHead
                ? MacosColors.systemGreenColor.withValues(alpha: 0.12)
                : selected
                ? AppTheme.rowSelectionTint
                : const Color(0x00000000),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
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
                Expanded(
                  child: Text(
                    branch.shortName,
                    style: typography.body.copyWith(
                      fontWeight: branch.isHead
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Checked out in ANOTHER worktree. `isHead` already means "checked
                // out here", so a worktreePath alongside a false isHead is the exact
                // test. git will refuse both checkout and delete for such a branch,
                // so say so up front instead of letting the user find out from a raw
                // error.
                if (elsewhere != null) ...[
                  const SizedBox(width: 6),
                  MacosTooltip(
                    // Shared wording + chip: History's ref chips render the same
                    // fact and the two had drifted apart in style and sentence.
                    message: checkedOutElsewhereMessage(elsewhere),
                    child: LabelChip(
                      elsewhere.split('/').last,
                      color: MacosColors.systemPurpleColor,
                      icon: kWorktreeIcon,
                    ),
                  ),
                ],
                if (branch.upstream != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    branch.upstream!,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ],
                // Divergence from upstream: the glanceable "does this need a
                // push/pull" signal, and — for [gone] — the classic "merged PR
                // left this behind" marker.
                if (branch.upstreamGone) ...[
                  const SizedBox(width: 6),
                  MacosTooltip(
                    message:
                        'The upstream branch was deleted (merged or removed on '
                        'the remote) — this local branch is likely stale',
                    child: Text(
                      'gone',
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemOrangeColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ] else if (branch.ahead > 0 || branch.behind > 0) ...[
                  const SizedBox(width: 6),
                  MacosTooltip(
                    message:
                        '${branch.ahead} commit${branch.ahead == 1 ? '' : 's'} '
                        'ahead, ${branch.behind} behind ${branch.upstream}',
                    child: Text(
                      [
                        if (branch.ahead > 0) '↑${branch.ahead}',
                        if (branch.behind > 0) '↓${branch.behind}',
                      ].join(' '),
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemBlueColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                // Rename applies to every local branch — including the current
                // one (`branch -m` follows HEAD) and one held by another worktree
                // (git updates that worktree's HEAD too).
                const SizedBox(width: 4),
                ToolIconButton(
                  icon: CupertinoIcons.pencil,
                  tooltip: 'Rename branch',
                  size: 14,
                  onPressed: busy
                      ? null
                      : () => _renameBranch(git, branch.shortName),
                ),
                if (!branch.isHead) ...[
                  const SizedBox(width: 4),
                  if (elsewhere != null)
                    // git refuses to check this out here ("already used by worktree
                    // at …") and there is no sensible override, so offer the thing
                    // the user actually wants: go to where it IS checked out.
                    ToolIconButton(
                      icon: CupertinoIcons.square_arrow_right,
                      tooltip: 'Switch to its worktree',
                      size: 15,
                      onPressed: busy
                          ? null
                          : () => _switchToWorktree(elsewhere),
                    )
                  else ...[
                    ToolIconButton(
                      icon: CupertinoIcons.square_arrow_down,
                      tooltip: 'Checkout branch',
                      size: 15,
                      onPressed: busy
                          ? null
                          : () => _checkout(git, branch.shortName),
                    ),
                    const SizedBox(width: 4),
                    // The most-requested worktree flow in every client's issue
                    // tracker: take this branch into a new checkout in one step,
                    // instead of switching away from what you are doing.
                    ToolIconButton(
                      icon: kWorktreeIcon,
                      tooltip: 'Checkout in a new worktree…',
                      size: 15,
                      onPressed: busy
                          ? null
                          : () => _checkoutInNewWorktree(branch.shortName),
                    ),
                  ],
                  const SizedBox(width: 4),
                  MacosPulldownButton(
                    icon: CupertinoIcons.arrow_merge,
                    items: [
                      MacosPulldownMenuItem(
                        title: const Text('Merge into current'),
                        onTap: () => _mergeBranch(
                          git,
                          branch.shortName,
                          MergeMode.normal,
                        ),
                      ),
                      MacosPulldownMenuItem(
                        title: const Text('Merge (no fast-forward)'),
                        onTap: () =>
                            _mergeBranch(git, branch.shortName, MergeMode.noFf),
                      ),
                      MacosPulldownMenuItem(
                        title: const Text('Merge (fast-forward only)'),
                        onTap: () => _mergeBranch(
                          git,
                          branch.shortName,
                          MergeMode.ffOnly,
                        ),
                      ),
                      MacosPulldownMenuItem(
                        title: const Text('Squash merge'),
                        onTap: () => _mergeBranch(
                          git,
                          branch.shortName,
                          MergeMode.squash,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  ToolIconButton(
                    icon: CupertinoIcons.trash,
                    tooltip: elsewhere == null
                        ? 'Delete branch'
                        // git refuses outright, and unlike checkout there is NO
                        // override flag for this — the worktree has to go first.
                        : 'Checked out in the worktree "${elsewhere.split('/').last}" '
                              '— remove that worktree first',
                    size: 14,
                    color: MacosColors.systemRedColor,
                    onPressed: busy || elsewhere != null
                        ? null
                        : () => _deleteBranch(git, branch.shortName),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Deletes a local branch, escalating to a force-delete confirmation when
  /// git rejects it as "not fully merged" — previously that error just
  /// dead-ended the flow with no recovery affordance short of reopening a
  /// terminal, even though `GitService.deleteBranch(force: true)` already
  /// existed and was simply never wired to anything.
  Future<void> _deleteBranch(GitService git, String name) async {
    if (busy) return;
    final ok = await confirmAction(
      context,
      title: 'Delete branch',
      message: 'Delete local branch "$name"?',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    // The escalation dialogs live INSIDE the guarded op (the same shape as
    // the worktrees panel's remove flow): a declined escalation returns
    // cleanly, an unclassified error rethrows into runGuarded's dialog, and
    // either way the always-refresh picks up whatever state the attempt left.
    await runGuarded(() async {
      try {
        await git.deleteBranch(repoPath, name);
      } on GitException catch (e) {
        if (!mounted) rethrow;
        // "cannot delete branch 'x' used by worktree at '/path'". There is no
        // override for this — `--ignore-other-worktrees` exists on checkout
        // and switch, but not on branch — so the ONLY way through is to
        // remove the worktree first. Offer exactly that, instead of
        // dead-ending on git's message. (Tower shipped a hang here; Fork
        // added this option in 2.63.)
        if (e.branchHeldByWorktree) {
          final worktree = _worktreePathFor(name);
          final removeToo = await confirmAction(
            context,
            title: 'Branch is checked out in a worktree',
            message: worktree == null
                ? 'This branch is checked out in another worktree. Remove that '
                      'worktree before deleting the branch.'
                : 'This branch is checked out in the worktree at\n$worktree\n\n'
                      'Git cannot delete a branch that is checked out. Remove '
                      'the worktree as well?',
            confirmLabel: 'Remove Worktree and Delete',
            destructive: true,
          );
          if (!removeToo || worktree == null || !mounted) return;
          await git.removeWorktree(repoPath, worktree, force: true);
          await git.deleteBranch(repoPath, name, force: true);
          return;
        }
        if (!e.branchNotFullyMerged) rethrow;
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
    });
  }

  Future<void> _mergeBranch(
    GitService git,
    String branch,
    MergeMode mode,
  ) async {
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

  /// Opens the Create Tag sheet (annotated toggle, message, push-after-create)
  /// — which replaced the old inline name-only bar. The bar could only produce
  /// the exact artifact that makes tags painful: lightweight, HEAD-only, and
  /// silently unpushed.
  Future<void> _openCreateTagSheet() async {
    final created = await showMacosSheet<bool>(
      context: context,
      builder: (_) => CreateTagSheet(repoPath: repoPath),
    );
    if (created == true && mounted) _refresh();
  }

  Widget _createTagBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AppPushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: busy ? null : _openCreateTagSheet,
          child: const Text('New Tag…'),
        ),
      ),
    );
  }

  /// Where a local tag stands relative to the remote's copy — computed from
  /// [remoteTagsProvider]'s listing. The oid comparison is ref-level
  /// (unpeeled), matching [GitRef.oid]: for an annotated tag both sides are
  /// the tag *object*, so a re-tagged same-commit tag correctly reads as
  /// [_TagRemoteStatus.differs] (its push WOULD be rejected).
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

  Widget _tagRow(
    BuildContext context,
    GitService git,
    GitRef tag,
    _TagRemoteStatus status,
    String? remote,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          // One Expanded around the whole informational cluster, no Spacer:
          // a loose Flexible sibling of a Spacer splits the free space with
          // it instead of yielding what it doesn't use, dragging the trailing
          // buttons toward the middle (the repo toolbar had this exact bug).
          Expanded(
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
          // No remote configured → nothing to push to; the button would only
          // ever produce an error.
          if (remote != null)
            ToolIconButton(
              icon: CupertinoIcons.cloud_upload,
              tooltip: switch (status) {
                _TagRemoteStatus.inSync => 'Already on $remote',
                _TagRemoteStatus.localOnly =>
                  'Push tag to $remote — not on the remote yet',
                _TagRemoteStatus.differs =>
                  'This tag differs from the one on $remote — the push will '
                      'be rejected. Delete the remote tag first to replace '
                      'it.',
                _TagRemoteStatus.unknown => 'Push tag to $remote',
              },
              size: 15,
              color: status == _TagRemoteStatus.localOnly
                  ? MacosColors.systemOrangeColor
                  : null,
              onPressed: busy || status == _TagRemoteStatus.inSync
                  ? null
                  : () => _pushTag(git, tag.shortName, remote),
            ),
          ToolIconButton(
            icon: CupertinoIcons.trash,
            tooltip: 'Delete tag',
            size: 14,
            color: MacosColors.systemRedColor,
            onPressed: busy ? null : () => _deleteTag(git, tag, status, remote),
          ),
        ],
      ),
    );
  }

  /// Pushes one tag — through the output log, like every network op (the old
  /// silent `runGuarded` variant left no trace of a push that DID happen).
  Future<void> _pushTag(GitService git, String name, String remote) async {
    final label = 'git push $remote refs/tags/$name';
    await runLogged(label, (log) async {
      log.logResult(label, await git.pushTag(repoPath, name, remote: remote));
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  /// Deletes a tag. When the remote listing says the tag also exists there,
  /// escalate to a three-way choice; the local delete stays journaled (⌘Z
  /// restores it), the remote one is not — the same asymmetry as branches.
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
      await runGuarded(() => git.deleteTag(repoPath, name));
      if (choice == _TagDeleteScope.both && mounted) {
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

  /// The Tags section header — with, when the remote listing shows local-only
  /// tags, the bulk escape hatch: push exactly those tags in one round trip.
  Widget _tagsHeader(
    BuildContext context,
    GitService git,
    int count,
    List<String> localOnly,
    String? remote,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Tags ($count)',
              style: MacosTheme.of(
                context,
              ).typography.caption1.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          if (localOnly.isNotEmpty && remote != null)
            AppPushButton(
              controlSize: ControlSize.small,
              secondary: true,
              onPressed: busy
                  ? null
                  : () => _pushAllLocalOnly(git, localOnly, remote),
              child: Text('Push ${localOnly.length} to $remote'),
            ),
        ],
      ),
    );
  }

  Future<void> _pushAllLocalOnly(
    GitService git,
    List<String> names,
    String remote,
  ) async {
    // Name them when the list is short; a count once it stops being readable.
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

  Widget _remoteRow(BuildContext context, GitService git, GitRef branch) {
    final typography = MacosTheme.of(context).typography;
    // Strip the remote name to get the branch git will DWIM a tracking checkout.
    final localName = branch.shortName.contains('/')
        ? branch.shortName.substring(branch.shortName.indexOf('/') + 1)
        : branch.shortName;
    return Padding(
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
          ToolIconButton(
            icon: CupertinoIcons.square_arrow_down,
            tooltip: 'Check out tracking branch',
            size: 15,
            onPressed: busy ? null : () => _checkout(git, localName),
          ),
          const SizedBox(width: 4),
          ToolIconButton(
            icon: CupertinoIcons.trash,
            tooltip: 'Delete branch on the remote',
            size: 14,
            color: MacosColors.systemRedColor,
            onPressed: busy
                ? null
                : () => _deleteRemoteBranch(git, branch.shortName),
          ),
        ],
      ),
    );
  }

  /// Deletes a branch on its remote (`git push --delete`). Destructive and
  /// NOT undoable from here — the commits may exist nowhere but the remote —
  /// so the confirm is explicit about both.
  Future<void> _deleteRemoteBranch(GitService git, String shortName) async {
    final slash = shortName.indexOf('/');
    if (slash <= 0) return; // not remote/branch shaped — nothing to target
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

  /// Renames a local branch via the shared name prompt. git carries reflog,
  /// upstream config, and any worktree HEADs across — see
  /// [GitService.renameBranch].
  Future<void> _renameBranch(GitService git, String oldName) async {
    final newName = await promptText(
      context,
      'Rename branch',
      placeholder: 'new name',
      initial: oldName,
    );
    if (newName == null || newName == oldName || !mounted) return;
    await runGuarded(() => git.renameBranch(repoPath, oldName, newName));
    // Follow the rename in the selection, so ↑/↓/Enter keep working on the
    // row the user was just acting on.
    if (mounted && _selectedBranch == oldName) {
      setState(() => _selectedBranch = newName);
    }
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      title,
      style: MacosTheme.of(
        context,
      ).typography.caption1.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  Widget _error(BuildContext context, Object err) => _Pad(
    child: Text(
      '$err',
      style: MacosTheme.of(
        context,
      ).typography.body.copyWith(color: MacosColors.systemRedColor),
    ),
  );
}

class _Pad extends StatelessWidget {
  final Widget child;
  const _Pad({required this.child});
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: child);
}

/// A row descriptor for [_BranchesViewState]'s `ListView.builder` — kept as
/// cheap data (not a built [Widget]) so flattening the list stays cheap even
/// for a repo with hundreds of branches/tags; only the actually-visible rows
/// get built.
sealed class _Row {
  const _Row();
}

class _CreateBranchRow extends _Row {
  const _CreateBranchRow();
}

class _CreateTagRow extends _Row {
  const _CreateTagRow();
}

class _HeaderRow extends _Row {
  final String title;
  const _HeaderRow(this.title);
}

class _BranchRow extends _Row {
  final GitRef branch;
  final bool remote;
  const _BranchRow(this.branch, {required this.remote});
}

class _TagRefRow extends _Row {
  final GitRef tag;
  const _TagRefRow(this.tag);
}

/// The Tags section header — its own descriptor (not [_HeaderRow]) because it
/// carries the "Push N to origin" affordance alongside the title.
class _TagsHeaderRow extends _Row {
  final int count;
  const _TagsHeaderRow(this.count);
}

class _ShowMoreTagsRow extends _Row {
  final int hidden;
  const _ShowMoreTagsRow(this.hidden);
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
