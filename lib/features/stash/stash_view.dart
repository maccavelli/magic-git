import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/theme/app_theme.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/busy_action.dart';
import '../common/diff_view.dart';
import '../common/label_chip.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/prompt_text_sheet.dart';
import '../common/resizable_master_detail.dart';
import '../common/tool_icon_button.dart';
import '../dnd/deselect.dart';
import '../dnd/drag_item.dart';

/// The **Stashes** namespace — stash management lifted out of the Branches pane
/// into its own top-level panel so parked work is easy to see and act on.
///
/// Layout: a left list of stash cards (ref, subject, origin branch, age, and
/// per-stash apply/pop/drop) beside a right preview of the selected stash's
/// patch. Stash-wide actions (stash current changes, pop/apply latest, clear
/// all) live under a hamburger menu in the header — the convention for toolbar
/// menus in this app.
class StashView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether the Stashes panel is the visible one — its apply/pop/drop
  /// shortcuts install only while active (the shell keeps it mounted in an
  /// IndexedStack otherwise).
  final bool isActive;

  const StashView({super.key, required this.repoPath, this.isActive = true});

  @override
  ConsumerState<StashView> createState() => _StashViewState();
}

class _StashViewState extends ConsumerState<StashView>
    with BusyActionState {
  /// The selected stash's OID — its STABLE identity. Selecting by position
  /// (`stash@{n}`) broke whenever the list shifted (a drop, a pop, an
  /// auto-stash from a branch switch): the highlight and preview silently
  /// moved to whatever slid into the old slot. An OID either still names the
  /// same stash or names nothing, so no re-targeting bookkeeping exists.
  String? _selected;

  // Serializes mutating stash operations. All of them (apply/pop/drop/clear,
  // stash push) route through [_runLogged], which shares this single flag —
  // Keyboard navigation of the stash list: the list takes focus on a card tap,
  // then ↑/↓ walk _selected through the stashes (⌥⌘A/⌥⌘P/⌘⌫ then act on it).
  final FocusNode _stashFocus = FocusNode(debugLabel: 'stash-list');
  final ScrollController _stashScroll = ScrollController();
  final Map<String, GlobalKey> _stashRowKeys = {};

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _stashFocus.dispose();
    _stashScroll.dispose();
    super.dispose();
  }

  GlobalKey _stashRowKeyFor(String oid) =>
      _stashRowKeys.putIfAbsent(oid, GlobalKey.new);

  void _moveStashSelection(int dir) {
    final stashes = ref.read(stashesProvider(repoPath)).value ?? const [];
    if (stashes.isEmpty) return;
    var current = -1;
    if (_selected != null) {
      for (var i = 0; i < stashes.length; i++) {
        if (stashes[i].oid == _selected) {
          current = i;
          break;
        }
      }
    }
    final next = stepSelection(current, dir, stashes.length);
    setState(() => _selected = stashes[next].oid);
    ensureRowVisible(_stashRowKeyFor(stashes[next].oid));
  }

  KeyEventResult _onStashKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || busy) {
      return KeyEventResult.ignored;
    }
    // Keys typed into a text field belong to the field, not the list — the
    // same gate PanelShortcuts applies to the ⌘-bindings (Esc in a field
    // must not clear the stash selection).
    if (PanelShortcuts.textInteractionHasFocus()) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveStashSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveStashSelection(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Canonical deselect — see dnd/deselect.dart for the Esc layering
        // (overlay closes first, then a live drag cancels, then this).
        return escDeselect(
          hasSelection: _selected != null,
          clear: () => setState(() => _selected = null),
        );
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(StashView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `_selected` is a stash OID from another repo's object database: this
    // State survives a repo switch (only the widget's repoPath changes), so
    // it can never match here — clear it. Mirrors HistoryView / RepoStatusView.
    if (oldWidget.repoPath != widget.repoPath) {
      _selected = null;
    }
  }

  void _refresh() {
    // The shared post-mutation refresh — this view's hand-rolled copy was the
    // sixth to drift (it forgot the own-mutation mark, so every stash op paid
    // for its refresh twice via the watcher echo).
    refreshAfterMutation(ref, repoPath);
  }

  // Apply/pop a specific stash — shared by the per-card icon buttons and the
  // apply/pop keyboard shortcuts so both take the identical logged path.
  Future<void> _apply(GitService git, GitStash stash) => _runLogged(
    'git stash apply ${stash.ref}',
    (log) async => log.logResult(
      'git stash apply ${stash.ref}',
      // By OID: immune to the list shifting since render.
      await git.stashApply(repoPath, stash.oid),
    ),
  );

  Future<void> _pop(GitService git, GitStash stash) => _runLogged(
    'git stash pop ${stash.ref}',
    (log) async => log.logResult(
      'git stash pop ${stash.ref}',
      // The OID guard: pops only if stash@{n} still IS this stash —
      // otherwise StashStaleException, and nothing was touched.
      await git.stashPop(repoPath, stash.index, expectedOid: stash.oid),
    ),
  );

  /// Runs a stash mutation through the shared [runLogged], adding this
  /// panel's one domain error: [StashStaleException] means the list shifted
  /// since render and NOTHING was modified — the always-refresh brings in the
  /// real list, so the dialog says so instead of showing raw git output.
  Future<bool> _runLogged(
    String title,
    Future<void> Function(OutputLogNotifier log) body,
  ) => runLogged(
    title,
    body,
    describeError: (e) =>
        e is StashStaleException ? '$e The list has been refreshed.' : null,
  );

  @override
  void refreshAfterAction() {
    // The preview pane renders stashDiffProvider for the selected OID —
    // re-fetch it alongside the list so a successful pop/drop can't leave a
    // stale diff for an entry that no longer exists.
    if (_selected != null) {
      ref.invalidate(stashDiffProvider((repoPath, _selected!)));
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final stashesAsync = ref.watch(stashesProvider(repoPath));
    final git = ref.read(gitServiceProvider);
    final count = stashesAsync.value?.length ?? 0;
    final keymap = ref.watch(keymapProvider);

    // The selected stash (if any) in the current list — apply/pop/drop act on it.
    GitStash? selEntry;
    if (_selected != null) {
      for (final s in stashesAsync.value ?? const <GitStash>[]) {
        if (s.oid == _selected) {
          selEntry = s;
          break;
        }
      }
    }

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'stashes.apply': selEntry == null ? null : () => _apply(git, selEntry!),
      'stashes.pop': selEntry == null ? null : () => _pop(git, selEntry!),
      'stashes.drop': selEntry == null
          ? null
          : () => _dropStash(context, git, selEntry!),
    };
    final live = widget.isActive && !busy;
    return PanelShortcuts(
      bindings: live
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: live ? handlers : const {},
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, git, count),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: stashesAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => SectionError(err),
            data: (stashes) {
              if (stashes.isEmpty) return _empty(context);
              // A selection is valid only while its stash still exists — an
              // OID match, never a position-vs-count comparison.
              final selected =
                  stashes.any((s) => s.oid == _selected) ? _selected : null;
              return ResizableMasterDetail(
                paneId: PaneId.stashList,
                master: Focus(
                  focusNode: _stashFocus,
                  onKeyEvent: _onStashKey,
                  child: DeselectOnEmptyClick(
                    onDeselect: () => setState(() => _selected = null),
                    child: ListView.builder(
                      controller: _stashScroll,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: stashes.length,
                      itemBuilder: (context, i) => _stashCard(
                        context,
                        git,
                        stashes[i],
                        stashes[i].oid == selected,
                      ),
                    ),
                  ),
                ),
                detail: _preview(context, selected),
              );
            },
          ),
        ),
      ],
      ),
    );
  }

  Widget _header(BuildContext context, GitService git, int count) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          const MacosIcon(CupertinoIcons.tray_2, size: 18),
          const SizedBox(width: 8),
          Text(
            'Stashes',
            style: typography.title3.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: typography.body.copyWith(color: MacosColors.systemGrayColor),
          ),
          const Spacer(),
          ToolIconButton(
            icon: CupertinoIcons.refresh,
            tooltip: 'Refresh',
            size: 16,
            onPressed: _refresh,
          ),
          const SizedBox(width: 4),
          _menu(context, git, count),
        ],
      ),
    );
  }

  /// Hamburger menu of stash-wide actions.
  Widget _menu(BuildContext context, GitService git, int count) {
    final hasStashes = count > 0;
    final canApplyOrPop = hasStashes && !busy;
    return MacosPulldownButtonTheme(
      // System-grey, matching the Repository and History toolbars' overflow
      // menus, instead of the pull-down theme's default gray.
      data: MacosPulldownButtonTheme.of(
        context,
      ).copyWith(iconColor: MacosColors.systemGrayColor),
      child: MacosPulldownButton(
        // Convention: toolbar menus use the "hamburger" (three horizontal lines).
        icon: CupertinoIcons.line_horizontal_3,
        items: [
          MacosPulldownMenuItem(
            title: Text(
              'Stash current changes',
              style: busy ? _disabledStyle(context) : null,
            ),
            onTap: busy
                ? null
                : () => _runLogged(
                    'git stash push',
                    (log) async => log.logResult(
                      'git stash push',
                      await git.stashPush(repoPath),
                    ),
                  ),
          ),
          MacosPulldownMenuItem(
            title: Text(
              'Stash including untracked',
              style: busy ? _disabledStyle(context) : null,
            ),
            onTap: busy
                ? null
                : () => _runLogged(
                    'git stash push --include-untracked',
                    (log) async => log.logResult(
                      'git stash push --include-untracked',
                      await git.stashPush(repoPath, includeUntracked: true),
                    ),
                  ),
          ),
          MacosPulldownMenuItem(
            title: Text(
              'Stash with message\u2026',
              style: busy ? _disabledStyle(context) : null,
            ),
            onTap: busy ? null : () => _stashWithMessage(git),
          ),
          MacosPulldownMenuItem(
            title: Text(
              'Apply latest stash',
              style: canApplyOrPop ? null : _disabledStyle(context),
            ),
            // Read at tap time, not render time — "latest" means the top of
            // the list as it exists NOW.
            onTap: canApplyOrPop ? () => _actOnLatest(git, pop: false) : null,
          ),
          MacosPulldownMenuItem(
            title: Text(
              'Pop latest stash',
              style: canApplyOrPop ? null : _disabledStyle(context),
            ),
            onTap: canApplyOrPop ? () => _actOnLatest(git, pop: true) : null,
          ),
          MacosPulldownMenuItem(
            title: Text(
              'Clear all stashes…',
              style: !canApplyOrPop
                  ? _disabledStyle(context)
                  : const TextStyle(color: MacosColors.systemRedColor),
            ),
            onTap: canApplyOrPop ? () => _clearAll(context, git) : null,
          ),
        ],
      ),
    );
  }

  /// Applies or pops whatever is at the TOP of the list right now — read at
  /// tap time so "latest" can't mean a stale render's idea of latest.
  Future<void> _actOnLatest(GitService git, {required bool pop}) async {
    final latest = ref.read(stashesProvider(repoPath)).value?.firstOrNull;
    if (latest == null) return;
    return pop ? _pop(git, latest) : _apply(git, latest);
  }

  /// Stash with a user-supplied name — the `-m` git always had but no UI
  /// exposed. Includes untracked files: naming a stash signals intent to keep
  /// it a while, and silently omitting untracked work from a kept stash is
  /// the footgun guardedBranchSwitch documents.
  Future<void> _stashWithMessage(GitService git) async {
    final message = await promptText(
      context,
      'Stash with message',
      placeholder: 'what this stash holds',
    );
    if (message == null || !mounted) return;
    await _runLogged(
      'git stash push -m',
      (log) async => log.logResult(
        'git stash push -m "$message"',
        await git.stashPush(
          repoPath,
          message: message,
          includeUntracked: true,
        ),
      ),
    );
  }

  TextStyle _disabledStyle(BuildContext context) =>
      const TextStyle(color: MacosColors.systemGrayColor);

  Future<void> _clearAll(BuildContext context, GitService git) async {
    final ok = await confirmAction(
      context,
      title: 'Clear all stashes',
      message:
          'Drop every stash in this repository? They are recorded first — '
          'press \u2318Z to undo, or restore them later from the Recovery '
          'view.',
      confirmLabel: 'Clear All',
      destructive: true,
    );
    if (!ok) return;
    setState(() => _selected = null);
    await _runLogged(
      'git stash clear',
      (log) async =>
          log.logResult('git stash clear', await git.stashClear(repoPath)),
    );
  }

  Widget _stashCard(
    BuildContext context,
    GitService git,
    GitStash stash,
    bool selected,
  ) {
    final typography = MacosTheme.of(context).typography;
    return DragItemDraggable(
      item: DragStash(stash),
      // Immediate (mouse-first) drag — see DragItemDraggable. Tap still selects.
      immediate: true,
      // Picking a card up selects it — identical to the tap path below, so the
      // selection (and its preview) follow the dragged stash (engine contract).
      onDragSelect: () {
        if (_selected == stash.oid) return;
        _stashFocus.requestFocus();
        setState(() => _selected = stash.oid);
      },
      child: GestureDetector(
      key: _stashRowKeyFor(stash.oid),
      onTap: () {
        _stashFocus.requestFocus();
        setState(() => _selected = stash.oid);
      },
      child: Container(
        color: selected
            ? AppTheme.rowSelectionTint
            : const Color(0x00000000),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: MacosIcon(
                CupertinoIcons.tray,
                size: 15,
                color: MacosColors.systemTealColor,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stash.subject,
                    style: typography.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      LabelChip('stash@{${stash.index}}', color: MacosColors.systemBlueColor),
                      if (stash.branch.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            stash.branch,
                            style: typography.caption1.copyWith(
                              color: MacosColors.systemGrayColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      if (stash.relativeDate.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '· ${stash.relativeDate}',
                            style: typography.caption1.copyWith(
                              color: MacosColors.systemGrayColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            ToolIconButton(
              icon: CupertinoIcons.tray_arrow_up,
              tooltip: 'Apply stash (keep in list)',
              size: 15,
              onPressed: busy ? null : () => _apply(git, stash),
            ),
            ToolIconButton(
              icon: CupertinoIcons.arrow_up_bin,
              tooltip: 'Pop stash (apply & remove)',
              size: 15,
              onPressed: busy ? null : () => _pop(git, stash),
            ),
            ToolIconButton(
              icon: CupertinoIcons.trash,
              tooltip: 'Drop stash',
              size: 14,
              color: MacosColors.systemRedColor,
              onPressed: busy ? null : () => _dropStash(context, git, stash),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Future<void> _dropStash(
    BuildContext context,
    GitService git,
    GitStash stash,
  ) async {
    final ok = await confirmAction(
      context,
      title: 'Drop stash',
      message:
          'Drop ${stash.ref}? It is recorded first — press \u2318Z to undo, '
          'or restore it later from the Recovery view.',
      confirmLabel: 'Drop',
      destructive: true,
    );
    if (!ok) return;
    await _runLogged(
      'git stash drop ${stash.ref}',
      (log) async => log.logResult(
        'git stash drop ${stash.ref}',
        await git.stashDrop(repoPath, stash.index, expectedOid: stash.oid),
      ),
    );
    // No selection re-targeting: `_selected` is an OID, which either still
    // names a surviving stash or matches nothing — positions shifting under
    // it cannot move the highlight onto the wrong entry.
  }

  Widget _preview(BuildContext context, String? selected) {
    if (selected == null) {
      return Center(
        child: Text(
          'Select a stash to preview its contents',
          style: MacosTheme.of(
            context,
          ).typography.body.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }
    final diffAsync = ref.watch(stashDiffProvider((repoPath, selected)));
    return diffAsync.when(
      loading: () => const DiffPending(),
      error: (err, _) => DiffFailure(err),
      data: (diff) => DiffView(diff: diff),
    );
  }

  Widget _empty(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MacosIcon(
            CupertinoIcons.tray,
            size: 40,
            color: MacosColors.systemGrayColor,
          ),
          const SizedBox(height: 12),
          Text('No stashes', style: typography.title3),
          const SizedBox(height: 6),
          Text(
            'Use the menu to stash your current changes.',
            style: typography.body.copyWith(color: MacosColors.systemGrayColor),
          ),
        ],
      ),
    );
  }

}
