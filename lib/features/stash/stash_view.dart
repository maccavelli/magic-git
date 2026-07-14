import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/diff_view.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/prompt_text_sheet.dart';
import '../common/tool_icon_button.dart';

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

class _StashViewState extends ConsumerState<StashView> {
  /// The selected stash's OID — its STABLE identity. Selecting by position
  /// (`stash@{n}`) broke whenever the list shifted (a drop, a pop, an
  /// auto-stash from a branch switch): the highlight and preview silently
  /// moved to whatever slid into the old slot. An OID either still names the
  /// same stash or names nothing, so no re-targeting bookkeeping exists.
  String? _selected;

  // Serializes mutating stash operations. All of them (apply/pop/drop/clear,
  // stash push) route through [_runLogged], which shares this single flag —
  // double-clicking "Drop" (or any other action) while the first tap's git
  // command is still in flight would otherwise fire two overlapping mutations
  // that race on `.git/index.lock`, or — for drop specifically — shift stash
  // indices out from under the second call once the first drop already
  // removed an earlier entry. While set, the toolbar/menu items go inert.
  bool _busy = false;

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
    if (event is KeyUpEvent || !widget.isActive || _busy) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveStashSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveStashSelection(-1);
        return KeyEventResult.handled;
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

  /// Runs a stash mutation, logging the command's output to the output view —
  /// stash pop/apply can conflict just like a merge, so the actual git output
  /// matters. Refreshes and re-previews on success.
  ///
  /// Returns whether the mutation actually succeeded — callers that need to
  /// adjust bookkeeping (e.g. [_dropStash] re-targeting [_selected] after a
  /// stash index shift) only do so once the underlying git command actually
  /// ran, since a failed drop leaves every index exactly where it was.
  Future<bool> _runLogged(
    String title,
    Future<void> Function(OutputLogNotifier log) body,
  ) async {
    // Guarded centrally here rather than at every call site: every mutating
    // stash action (push/apply/pop/drop/clear) routes through this method —
    // see [_busy]. A re-entrant call while one is already in flight is a no-op.
    if (_busy) return false;
    setState(() => _busy = true);
    final log = ref.read(outputLogProvider.notifier);
    var success = false;
    try {
      await body(log);
      success = true;
    } on StashStaleException catch (e) {
      // The guard refused: the list shifted since it was rendered and the
      // positional ref no longer names what the user clicked. Nothing was
      // modified; the finally-refresh below brings the real list in.
      if (mounted) {
        await showErrorDialog(context, '$e The list has been refreshed.');
      }
    } on GitException catch (e) {
      log.logResult(title, e.result);
      if (mounted) await showErrorDialog(context, e.toString());
    } catch (e) {
      log.logError(title, e.toString());
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      // Refresh on FAILURE too — a conflicting pop/apply throws GitException
      // but has already rewritten the working tree, and the status/pendingOp
      // providers must pick that up now, not on some later unrelated refresh
      // (the same fix repo_status and history landed; this copy predated it).
      // `mounted` guards the whole block: the view can be torn down while a
      // slow pop is in flight, and touching `ref` after disposal throws.
      if (mounted) {
        if (_selected != null) {
          ref.invalidate(stashDiffProvider((repoPath, _selected!)));
        }
        _refresh();
        setState(() => _busy = false);
      }
    }
    return success;
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

    return PanelShortcuts(
      bindings: widget.isActive && !_busy
          ? resolveShortcuts(keymap, {
              'stashes.apply': selEntry == null
                  ? null
                  : () => _apply(git, selEntry!),
              'stashes.pop': selEntry == null
                  ? null
                  : () => _pop(git, selEntry!),
              'stashes.drop': selEntry == null
                  ? null
                  : () => _dropStash(context, git, selEntry!),
            })
          : const <ShortcutActivator, VoidCallback>{},
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, git, count),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: stashesAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => _error(context, err),
            data: (stashes) {
              if (stashes.isEmpty) return _empty(context);
              // A selection is valid only while its stash still exists — an
              // OID match, never a position-vs-count comparison.
              final selected =
                  stashes.any((s) => s.oid == _selected) ? _selected : null;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 360,
                    child: Focus(
                      focusNode: _stashFocus,
                      onKeyEvent: _onStashKey,
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
                  Container(width: 1, color: MacosColors.separatorColor),
                  Expanded(child: _preview(context, selected)),
                ],
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
    final canApplyOrPop = hasStashes && !_busy;
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
              style: _busy ? _disabledStyle(context) : null,
            ),
            onTap: _busy
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
              style: _busy ? _disabledStyle(context) : null,
            ),
            onTap: _busy
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
              style: _busy ? _disabledStyle(context) : null,
            ),
            onTap: _busy ? null : () => _stashWithMessage(git),
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
    return GestureDetector(
      key: _stashRowKeyFor(stash.oid),
      onTap: () {
        _stashFocus.requestFocus();
        setState(() => _selected = stash.oid);
      },
      child: Container(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
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
                      _chip('stash@{${stash.index}}'),
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
              onPressed: _busy ? null : () => _apply(git, stash),
            ),
            ToolIconButton(
              icon: CupertinoIcons.arrow_up_bin,
              tooltip: 'Pop stash (apply & remove)',
              size: 15,
              onPressed: _busy ? null : () => _pop(git, stash),
            ),
            ToolIconButton(
              icon: CupertinoIcons.trash,
              tooltip: 'Drop stash',
              size: 14,
              color: MacosColors.systemRedColor,
              onPressed: _busy ? null : () => _dropStash(context, git, stash),
            ),
          ],
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

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: MacosColors.systemBlueColor.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: MacosColors.systemBlueColor,
      ),
    ),
  );

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

  Widget _error(BuildContext context, Object err) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        '$err',
        style: MacosTheme.of(
          context,
        ).typography.body.copyWith(color: MacosColors.systemRedColor),
      ),
    ),
  );
}
