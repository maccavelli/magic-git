import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import '../../core/theme/app_theme.dart';
import '../common/actions.dart';
import '../common/adaptive_workspace_layout.dart';
import '../common/busy_action.dart';
import '../common/context_menu.dart';
import '../common/diff_view.dart';
import '../common/field_styles.dart';
import '../common/label_chip.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/prompt_text_sheet.dart';
import '../common/ref_name_validation.dart';
import '../common/repository_context.dart';
import '../common/repository_context_bar.dart';
import '../common/repository_workspace_scaffold.dart';
import '../common/tool_icon_button.dart';
import '../common/workspace_focus.dart';
import '../common/workspace_navigation.dart';
import '../common/workspace_preferences_binding.dart';
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

class _StashViewState extends ConsumerState<StashView> with BusyActionState {
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
  final TextEditingController _filterController = TextEditingController();
  final Map<String, GlobalKey> _stashRowKeys = {};

  /// Per-card right-click menu — the discoverable home for the less-common
  /// affordances (apply/pop with `--index`, create-branch-from-stash) that
  /// would clutter the card's inline buttons.
  final ContextMenuOverlay _cardMenu = ContextMenuOverlay();

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _cardMenu.dispose();
    _stashFocus.dispose();
    _stashScroll.dispose();
    _filterController.dispose();
    super.dispose();
  }

  GlobalKey _stashRowKeyFor(String oid) =>
      _stashRowKeys.putIfAbsent(oid, GlobalKey.new);

  void _moveStashSelection(int dir) {
    final stashes = _visibleStashes(
      ref.read(stashesProvider(repoPath)).value ?? const [],
    );
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

  List<GitStash> _visibleStashes(List<GitStash> stashes) {
    final query = _filterController.text.trim().toLowerCase();
    if (query.isEmpty) return stashes;
    return [
      for (final stash in stashes)
        if (stash.subject.toLowerCase().contains(query) ||
            stash.branch.toLowerCase().contains(query) ||
            stash.oid.toLowerCase().contains(query) ||
            stash.ref.toLowerCase().contains(query))
          stash,
    ];
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
      // The row-key map and scroll offset belong to the old repo's list.
      // Without this the OID-keyed keys accrete across every repo switch
      // (a slow GlobalKey leak) and the new repo's list opens scrolled to
      // the previous one's position. Mirrors BranchesView.didUpdateWidget.
      _stashRowKeys.clear();
      _filterController.clear();
      if (_stashScroll.hasClients) _stashScroll.jumpTo(0);
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
  Future<void> _apply(
    GitService git,
    GitStash stash, {
    bool restoreIndex = false,
  }) {
    final label = restoreIndex
        ? 'git stash apply --index ${stash.ref}'
        : 'git stash apply ${stash.ref}';
    return _runLogged(
      label,
      (log) async => log.logResult(
        label,
        // By OID: immune to the list shifting since render.
        await git.stashApply(repoPath, stash.oid, restoreIndex: restoreIndex),
      ),
    );
  }

  Future<void> _pop(
    GitService git,
    GitStash stash, {
    bool restoreIndex = false,
  }) {
    final label = restoreIndex
        ? 'git stash pop --index ${stash.ref}'
        : 'git stash pop ${stash.ref}';
    return _runLogged(
      label,
      (log) async => log.logResult(
        label,
        // The OID guard: pops only if stash@{n} still IS this stash —
        // otherwise StashStaleException, and nothing was touched.
        await git.stashPop(
          repoPath,
          stash.index,
          expectedOid: stash.oid,
          restoreIndex: restoreIndex,
        ),
      ),
    );
  }

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
    // Only the stash LIST changes on a mutation. A stash's patch is immutable
    // for a given OID and stashDiffProvider is keyed by that OID, so there is
    // nothing to invalidate for the preview — refreshing the list is the whole
    // job. (A dropped/popped OID simply stops being watched once the build
    // filters _selected against the surviving stashes.)
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final stashesAsync = ref.watch(stashesProvider(repoPath));
    final git = ref.read(gitServiceProvider);
    final count = stashesAsync.value?.length ?? 0;
    final keymap = ref.watch(keymapProvider);
    final connection = ref.watch(connectionProvider);
    final refs = refsProvider(repoPath);
    final landedRefs = ref.exists(refs)
        ? ref.read(refs).value ?? const <GitRef>[]
        : const <GitRef>[];
    final head = landedRefs.where((item) => item.isHead).firstOrNull;
    final stashListWidth = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.paneWidth(PaneId.stashList),
      ),
    );
    final workspace = watchWorkspacePreferences(
      context: context,
      ref: ref,
      repositoryPath: repoPath,
      fallback: RepositoryWorkspacePrefs(navigatorWidth: stashListWidth),
      preserveFallbackNavigatorWidth: true,
      onLegacyChanged: (next) {
        ref
            .read(appSettingsProvider.notifier)
            .setPaneWidth(PaneId.stashList, next.navigatorWidth)
            .ignore();
      },
    );

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
    final supplementKey = connection.sessionEpoch > 0
        ? RepositoryContextSupplementKey(
            repositoryIdentity: repositoryContextIdentityKey(
              backend: connection.backend.name,
              connectionId: connection.connectionId,
              repositoryPath: repoPath,
            ),
            sessionEpoch: connection.sessionEpoch,
          )
        : null;
    if (supplementKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(repositoryContextSupplementCacheProvider.notifier)
            .publish(
              supplementKey,
              RepositoryContextSupplement(
                selectionLabel: selEntry == null
                    ? '$count stashes'
                    : 'Stash: ${selEntry.ref} · ${selEntry.subject}',
              ),
            );
        if (selEntry != null) {
          ref
              .read(
                workspaceNavigationProvider(
                  WorkspaceSessionKey(repoPath, connection.sessionEpoch),
                ).notifier,
              )
              .visit(
                WorkspaceFocus(
                  repositoryPath: repoPath,
                  sessionEpoch: connection.sessionEpoch,
                  kind: WorkspaceFocusKind.stash,
                  identity: selEntry.oid,
                  panelIndex: 3,
                ),
              );
        }
      });
    }
    final pathParts = repoPath.split('/').where((part) => part.isNotEmpty);
    final snapshot = RepositoryContextSnapshot(
      repositoryPath: repoPath,
      repositoryName:
          'Repository: ${pathParts.isEmpty ? repoPath : pathParts.last}',
      connectionLabel: connection.connectionLabel,
      hostLabel: connection.isLocal ? 'On this Mac' : connection.host,
      branchLabel: head == null ? 'Repository' : 'Branch: ${head.shortName}',
      upstreamLabel: head?.upstream,
      ahead: head?.ahead ?? 0,
      behind: head?.behind ?? 0,
      hasUpstream: head?.upstream != null,
      hasConfiguredRemote: landedRefs.any((item) => item.isRemote),
      connected: connection.isConnected,
      busy: busy,
      refCount: landedRefs.length,
      supplement: supplementKey == null
          ? null
          : ref.watch(
              repositoryContextSupplementCacheProvider.select(
                (cache) => cache[supplementKey],
              ),
            ),
    );
    return PanelShortcuts(
      bindings: live
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: live ? handlers : const {},
      child: stashesAsync.when(
        loading: () => RepositoryWorkspaceScaffold(
          repositoryContext: _contextBar(snapshot, git),
          canvas: const SizedBox.shrink(),
          loading: true,
          preferences: workspace.preferences,
          onPreferencesChanged: workspace.onChanged,
          workspaceOptionsEnabled: true,
        ),
        error: (err, _) => RepositoryWorkspaceScaffold(
          repositoryContext: _contextBar(snapshot, git),
          canvas: const SizedBox.shrink(),
          error: err,
          onRetry: _refresh,
          preferences: workspace.preferences,
          onPreferencesChanged: workspace.onChanged,
          workspaceOptionsEnabled: true,
        ),
        data: (stashes) {
          final visible = _visibleStashes(stashes);
          final selected = stashes.any((stash) => stash.oid == _selected)
              ? _selected
              : null;
          return RepositoryWorkspaceScaffold(
            repositoryContext: _contextBar(snapshot, git),
            navigator: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _filterBar(context, git, count, visible.length),
                Container(height: 1, color: MacosColors.separatorColor),
                Expanded(
                  child: visible.isEmpty
                      ? stashes.isEmpty
                            ? const SizedBox.shrink()
                            : const Center(child: Text('No matching stashes'))
                      : Focus(
                          focusNode: _stashFocus,
                          onKeyEvent: _onStashKey,
                          child: DeselectOnEmptyClick(
                            onDeselect: () => setState(() => _selected = null),
                            child: ListView.builder(
                              controller: _stashScroll,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: visible.length,
                              itemBuilder: (context, i) => _stashCard(
                                context,
                                git,
                                visible[i],
                                visible[i].oid == selected,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
            canvas: stashes.isEmpty
                ? _empty(context)
                : _preview(context, selected),
            activePage: selected == null
                ? CompactWorkspacePage.navigator
                : CompactWorkspacePage.canvas,
            preferences: workspace.preferences,
            onPreferencesChanged: workspace.onChanged,
            workspaceOptionsEnabled: true,
          );
        },
      ),
    );
  }

  /// THE stash-everything path. Every entry point routes here.
  ///
  /// `--include-untracked` is not optional: plain `git stash push` ignores
  /// untracked files and then "succeeds" with an empty "No local changes to
  /// save" — creating no stash while reporting success, and leaving the work
  /// in place (the same hazard `branch_switch.dart` documents for auto-stash).
  /// Two entry points here used to omit it, so the identically-labelled button
  /// on this screen and the one on Repository did different things.
  Future<void> _stashAll(GitService git) => _runLogged(
    'git stash push --include-untracked',
    (log) async => log.logResult(
      'git stash push --include-untracked',
      await git.stashPush(repoPath, includeUntracked: true),
    ),
  );

  Widget _contextBar(RepositoryContextSnapshot snapshot, GitService git) =>
      RepositoryContextBar(
        snapshot: snapshot,
        primaryAction: RepositoryPrimaryAction(
          kind: RepositoryPrimaryActionKind.fetch,
          label: 'Stash Changes',
          disabledReason: busy ? 'Another stash operation is running' : null,
        ),
        onPrimaryAction: (_) => _stashAll(git),
      );

  Widget _filterBar(
    BuildContext context,
    GitService git,
    int count,
    int visibleCount,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
    child: Column(
      children: [
        Row(
          children: [
            Text(
              'Stashes',
              style: MacosTheme.of(
                context,
              ).typography.headline.copyWith(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              visibleCount == count ? '$count' : '$visibleCount of $count',
              style: MacosTheme.of(context).typography.caption1,
            ),
            ToolIconButton(
              icon: CupertinoIcons.refresh,
              tooltip: 'Refresh',
              size: 16,
              onPressed: _refresh,
            ),
            _menu(context, git, count),
          ],
        ),
        const SizedBox(height: 6),
        MacosTextField(
          controller: _filterController,
          placeholder: 'Filter stashes',
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          prefix: const Padding(
            padding: EdgeInsets.only(left: 6),
            child: MacosIcon(CupertinoIcons.search, size: 13),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    ),
  );

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
          // One item, not two: "including untracked" IS the behaviour now, so
          // a separate entry would offer a distinction that no longer exists.
          MacosPulldownMenuItem(
            title: Text(
              'Stash changes',
              style: busy ? _disabledStyle(context) : null,
            ),
            onTap: busy ? null : () => _stashAll(git),
          ),
          MacosPulldownMenuItem(
            title: Text(
              'Stash with message\u2026',
              style: busy ? _disabledStyle(context) : null,
            ),
            onTap: busy ? null : () => _stashWithMessage(git),
          ),
          // These act on the LATEST stash, whereas the row buttons and
          // ⌥⌘A/⌥⌘P act on the SELECTED one. Same verbs, different operand —
          // so the operand is named in the label rather than left implicit.
          const MacosPulldownMenuItem(
            title: Text('\u2014'),
            enabled: false,
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
        await git.stashPush(repoPath, message: message, includeUntracked: true),
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
    // The confirm awaited a dialog; the workspace can disconnect (this View
    // unmounts) while it was open — guard the setState like _stashWithMessage.
    if (!ok || !mounted) return;
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
        onSecondaryTapUp: (d) =>
            _showCardMenu(context, git, stash, d.globalPosition),
        child: Container(
          color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
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
                        LabelChip(
                          'stash@{${stash.index}}',
                          color: MacosColors.systemBlueColor,
                        ),
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

  /// Recovers the stash onto a brand-new branch (`git stash branch`) — the
  /// escape hatch for a stash that won't apply to the current branch.
  Future<void> _branchFromStash(GitService git, GitStash stash) async {
    final name = await promptText(
      context,
      'Create branch from stash',
      placeholder: 'branch name',
      description:
          'Creates a branch at ${stash.ref}’s base commit, applies the '
          'stash there, and drops it. ⌘Z undoes the whole thing.',
      validate: refNameProblem,
    );
    if (name == null || !mounted) return;
    final label = 'git stash branch $name ${stash.ref}';
    await _runLogged(
      label,
      (log) async => log.logResult(
        label,
        await git.stashBranch(
          repoPath,
          name,
          index: stash.index,
          expectedOid: stash.oid,
        ),
      ),
    );
  }

  /// The stash card's right-click menu: the inline buttons cover apply/pop/drop
  /// at a click; this adds the `--index` variants and create-branch-from-stash
  /// without crowding the row. Selecting the card first mirrors the tap path.
  void _showCardMenu(
    BuildContext context,
    GitService git,
    GitStash stash,
    Offset pos,
  ) {
    _stashFocus.requestFocus();
    setState(() => _selected = stash.oid);
    // Match the buttons' busy gate — no mutation menu while one is in flight.
    if (busy) return;
    _cardMenu.show(context, pos, [
      ContextMenuItem(
        icon: CupertinoIcons.tray_arrow_up,
        label: 'Apply (keep in list)',
        onTap: () => _apply(git, stash),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.tray_arrow_up,
        label: 'Apply, restoring staged files',
        onTap: () => _apply(git, stash, restoreIndex: true),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_up_bin,
        label: 'Pop (apply & remove)',
        onTap: () => _pop(git, stash),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_up_bin,
        label: 'Pop, restoring staged files',
        onTap: () => _pop(git, stash, restoreIndex: true),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_branch,
        label: 'Create branch from stash…',
        onTap: () => _branchFromStash(git, stash),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Drop',
        iconColor: MacosColors.systemRedColor,
        onTap: () => _dropStash(context, git, stash),
      ),
    ], width: 260);
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
