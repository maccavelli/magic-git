import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/git/unified_diff.dart';
import '../../core/git/watch_event.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/keymap.dart';
import '../../core/utils/file_actions.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/context_menu.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/split_diff_view.dart';
import '../common/status_style.dart';
import '../common/tool_icon_button.dart';
import '../settings/settings_sheet.dart';
import 'blame_sheet.dart';
import 'commit_dialog.dart';
import 'conflict_view.dart';
import 'diff_popout_window.dart';
import 'file_view.dart';
import 'hunk_diff_view.dart';
import 'output_view.dart';

/// How to proceed when a plain push would be rejected because the branch is
/// behind its upstream.
enum _PushChoice { pullThenPush, pushAnyway, cancel }

/// Which status section a selection belongs to. A selection never spans
/// sections (see [_RepoStatusViewState._handleRowTap]) — mixing, say, one
/// staged and one unstaged file makes "Stage"/"Discard" ambiguous — so this
/// single value describes every currently-selected path at once.
enum _SectionKind { conflict, staged, unstaged, untracked }

/// Live working-tree status for the connected repository. Proves the end-to-end
/// path: SSH → `git status --porcelain=v2 -z` → isolate parse → reactive UI,
/// with event-driven refresh from the remote watcher. Selecting a file shows
/// its diff alongside the list.
class RepoStatusView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether this panel is the currently-visible sidebar page. It stays
  /// mounted (via the shell's [IndexedStack]) when another page is shown, so
  /// its keyboard shortcuts must go quiet rather than fire in the background.
  final bool isActive;

  const RepoStatusView({
    super.key,
    required this.repoPath,
    this.isActive = true,
  });

  @override
  ConsumerState<RepoStatusView> createState() => _RepoStatusViewState();
}

class _RepoStatusViewState extends ConsumerState<RepoStatusView> {
  // Which status section the current selection belongs to; null means
  // nothing is selected.
  _SectionKind? _selectionKind;
  // Paths currently selected within _selectionKind's section. A lone path is
  // the common case and drives the diff/conflict panel; 2+ show the
  // multi-select summary panel instead.
  Set<String> _selectedPaths = {};
  // Anchor for shift-click range selection: the fixed end a range extends
  // from, so repeated shift-clicks extend/contract from the same point
  // rather than the last-clicked row.
  String? _selectionAnchor;

  // Single-file view of the selection — non-null only when exactly one
  // non-conflict file is selected. Named record so field reads are
  // self-checking (transposing staged/untracked was previously a silent
  // bug); every call site that cares about "the one selected file" (the diff
  // panel, keyboard shortcuts, stage/unstage bookkeeping) reads this instead
  // of _selectedPaths directly.
  ({String path, bool staged, bool untracked})? get _selected {
    final kind = _selectionKind;
    if (kind == null || kind == _SectionKind.conflict) return null;
    if (_selectedPaths.length != 1) return null;
    return (
      path: _selectedPaths.single,
      staged: kind == _SectionKind.staged,
      untracked: kind == _SectionKind.untracked,
    );
  }

  // Single-conflict view of the selection — non-null only when exactly one
  // conflicted file is selected.
  String? get _selectedConflict =>
      _selectionKind == _SectionKind.conflict && _selectedPaths.length == 1
      ? _selectedPaths.single
      : null;

  bool get _isMultiSelect => _selectedPaths.length > 1;

  // Diff-viewer ergonomics (persist across selections within a session):
  //  * split → side-by-side rendering (read-only) vs unified with staging;
  //  * ignoreWhitespace → `-w`; also forces read-only (a -w diff isn't a valid
  //    apply patch);
  //  * expandContext → widen context lines from the default to [_expandedCtx].
  bool _diffSplit = false;
  bool _diffIgnoreWs = false;
  bool _diffExpandContext = false;
  static const _defaultCtx = 3;
  static const _expandedCtx = 25;
  int get _diffCtx => _diffExpandContext ? _expandedCtx : _defaultCtx;

  /// Diff-prefetch bookkeeping — see [_prefetchDiffs].
  DateTime? _lastDiffPrefetch;
  static const int _prefetchMaxFiles = 8;
  static const Duration _prefetchMinGap = Duration(seconds: 5);

  /// Warms the diff cache for the first few changed files whenever a fresh
  /// status lands, so clicking a file renders its diff from RAM instantly
  /// instead of paying an SSH round trip — the single biggest "feels local"
  /// lever for a remote repo. The keys are built exactly the way a click
  /// builds them (same ignore-whitespace/context settings), so the provider
  /// cache hit is guaranteed; the fetches ride the executor's concurrent read
  /// lane, so they never delay an interactive command behind them. Throttled
  /// to once per [_prefetchMinGap] so a churning repo (a build writing files,
  /// one coalesced watcher tick per second) doesn't refetch the whole set
  /// every tick; conflicted files are skipped (the conflict pane uses a
  /// different provider and needs user attention anyway).
  void _prefetchDiffs(GitStatus? status) {
    if (status == null || !widget.isActive) return;
    final now = DateTime.now();
    final last = _lastDiffPrefetch;
    if (last != null && now.difference(last) < _prefetchMinGap) return;
    _lastDiffPrefetch = now;
    var n = 0;
    for (final f in status.files) {
      if (n >= _prefetchMaxFiles) break;
      if (f.isUnmerged) continue;
      if (f.isUntracked) {
        // `.ignore()`: a prefetch failure (or a mid-fetch invalidation from
        // the next status landing) must never surface anywhere — the real
        // read simply happens on click as before.
        ref.read(untrackedDiffProvider((repoPath, f.path)).future).ignore();
      } else {
        // Prefetch the pane a click would open: the worktree diff when the
        // file has unstaged changes, else its staged diff.
        final staged = !f.isUnstaged;
        ref
            .read(
              fileDiffProvider((
                repoPath,
                f.path,
                staged,
                _diffIgnoreWs,
                _diffCtx,
              )).future,
            )
            .ignore();
      }
      n++;
    }
  }

  // Whether the diff has been "popped out" into a floating window — see
  // DiffPopoutWindow. Relocates where the diff is shown; _selected still
  // tracks which file it's for.
  bool _popout = false;

  // How long after this app's own mutation a watch tick is assumed to be
  // reporting that same change (SSH round trip + the watcher's own
  // coalescing window) rather than a genuinely concurrent external one.
  static const _ownMutationSuppressWindow = Duration(seconds: 3);

  // Serializes mutating git operations. The working index and refs are shared
  // state, so two overlapping writes — a double-clicked Push, or a Stage fired
  // during an in-flight Pull — race on `.git/index.lock` and surface spurious
  // lock/rejection errors. While set, mutating toolbar buttons and shortcuts go
  // inert and any re-entrant mutation no-ops.
  bool _busy = false;

  // Right-click context menu, anchored at the tap point.
  final _contextMenu = ContextMenuOverlay();

  // Keyboard navigation of the file list: the list takes focus on a row tap,
  // after which ↑/↓ walk the single selection through the file rows (Space then
  // stages it — see the keymap wiring). Per-row GlobalKeys let the selected row
  // scroll into view.
  final _listFocus = FocusNode(debugLabel: 'status-file-list');
  final _listScroll = ScrollController();
  final Map<String, GlobalKey> _rowKeys = {};

  // Memoized status-row model. `_statusRows` allocates a header/file row per
  // changed file across every section, and this widget setState()s constantly
  // (each selection tap, the _busy toggle wrapping every git op, each diff
  // toggle). Riverpod hands back the *same* GitStatus instance until
  // statusProvider is invalidated, so the derivation is cached on that identity
  // and rebuilt only when the status actually changes — not on every frame. For
  // a large working tree this turns a per-interaction N-object re-derivation
  // into a cheap identity check.
  GitStatus? _rowsForStatus;
  List<_StatusRow> _rows = const [];

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _contextMenu.dispose();
    _listFocus.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  GlobalKey _rowKeyFor(String path, _SectionKind kind) =>
      _rowKeys.putIfAbsent('${kind.name}:$path', GlobalKey.new);

  /// Walks the single selection [dir] rows through the flattened file rows
  /// (headers skipped), across all sections, and scrolls it into view. With
  /// nothing selected, Down lands on the first file row and Up on the last.
  void _moveFileSelection(int dir) {
    final fileRows = <_FileRow>[
      for (final r in _rows)
        if (r is _FileRow) r,
    ];
    if (fileRows.isEmpty) return;
    var current = -1;
    if (_selectedPaths.length == 1 && _selectionKind != null) {
      final path = _selectedPaths.single;
      for (var i = 0; i < fileRows.length; i++) {
        if (fileRows[i].file.path == path &&
            _kindOfFileRow(fileRows[i]) == _selectionKind) {
          current = i;
          break;
        }
      }
    }
    final next = stepSelection(current, dir, fileRows.length);
    final row = fileRows[next];
    final kind = _kindOfFileRow(row);
    setState(() {
      _selectionKind = kind;
      _selectedPaths = {row.file.path};
      _selectionAnchor = row.file.path;
      _popout = false;
    });
    ensureRowVisible(_rowKeyFor(row.file.path, kind));
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || _busy) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveFileSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveFileSelection(-1);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(RepoStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      // Dismiss any open right-click menu — it targets the old repo's
      // file(s) and its actions would otherwise run against the new repo.
      _contextMenu.remove();
      _selectionKind = null;
      _selectedPaths = {};
      _selectionAnchor = null;
      _popout = false;
    }
    // The watch listener skips refetching status while this page is hidden (see
    // build). Re-sync once when it becomes visible again so nothing missed while
    // away is left stale — cheaper than the per-tick background fetches the gate
    // avoids, and it makes the gate safe in both event-driven and polling modes.
    // Deferred past this frame: invalidating synchronously in didUpdateWidget
    // (which runs during build) would mark the provider scope dirty mid-build.
    if (!oldWidget.isActive && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(statusProvider(repoPath));
      });
    }
  }

  void _refresh() {
    // Guarded centrally here rather than at every call site: several async
    // ops (stage/unstage/push/pull/…) call this right after an await with no
    // further check of their own, and touching `ref` after the widget is
    // disposed throws.
    if (!mounted) return;
    // Marks this moment so the watch-tick listener below can recognize its
    // own subsequent tick (for this very mutation) as redundant.
    ref.read(ownMutationTrackerProvider).mark(repoPath);
    // sequencerStateProvider follows statusProvider, so invalidating status
    // refreshes it too — no separate invalidation needed.
    ref.invalidate(statusProvider(repoPath));
    ref.invalidate(logProvider(repoPath));
    ref.invalidate(refsProvider(repoPath));
    ref.invalidate(stashesProvider(repoPath));
    // The open diff panel isn't covered by the invalidations above — every
    // mutating action that routes through here (stage/unstage/discard/
    // resolve/abort/continue) can change the currently-viewed file's diff, so
    // refresh whichever key the panel is actually showing.
    final sel = _selected;
    if (sel != null) {
      final (:path, :staged, :untracked) = sel;
      if (untracked) {
        ref.invalidate(untrackedDiffProvider((repoPath, path)));
      } else {
        ref.invalidate(
          fileDiffProvider((repoPath, path, staged, _diffIgnoreWs, _diffCtx)),
        );
      }
    }
  }

  Future<void> _stage(String path) async {
    final git = ref.read(gitServiceProvider);
    if (await _guardedAction(() => git.stage(repoPath, path))) {
      if (!mounted) return;
      // Flip the diff panel's staged flag immediately for the file just
      // staged, rather than leaving it pointed at the pre-stage diff key
      // until the next status refetch lands.
      _dropOrReselect(path, _SectionKind.staged);
    }
  }

  Future<void> _unstage(String path) async {
    final git = ref.read(gitServiceProvider);
    if (await _guardedAction(() => git.unstage(repoPath, path))) {
      if (!mounted) return;
      _dropOrReselect(path, _SectionKind.unstaged);
    }
  }

  /// A single-file action (stage/unstage/discard icon on a row) just moved
  /// [path] into [newKind]'s section. If [path] was the *sole* selection,
  /// follow it there — this is what keeps the diff panel pointed at the
  /// file's new state instead of going stale or closing. If [path] was one
  /// of several selected files, it no longer belongs with the rest of that
  /// selection (which is still in the old section), so just drop it rather
  /// than guessing whether the user wants it re-homed.
  void _dropOrReselect(String path, _SectionKind newKind) {
    if (!_selectedPaths.contains(path)) return;
    setState(() {
      if (_selectedPaths.length == 1) {
        _selectionKind = newKind;
        _selectionAnchor = path;
      } else {
        _selectedPaths = {..._selectedPaths}..remove(path);
      }
    });
  }

  /// Removes [path] from the selection if present, with no reselection —
  /// used when an action makes [path] disappear from the status list
  /// entirely (e.g. a resolved conflict), so the panel doesn't keep pointing
  /// at it until the next status refetch lands.
  void _removeFromSelection(String path) {
    if (!_selectedPaths.contains(path)) return;
    setState(() {
      _selectedPaths = {..._selectedPaths}..remove(path);
      if (_selectedPaths.isEmpty) _selectionKind = null;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectionKind = null;
      _selectedPaths = {};
    });
  }

  Future<void> _stageAll() async {
    final git = ref.read(gitServiceProvider);
    await _guardedAction(() => git.stageAll(repoPath));
  }

  Future<void> _openCommitDialog(int stagedCount) async {
    // The dialog pops with `true` when the user chose Commit & Push (⌘⇧↩), so
    // the push runs here — after the sheet closes — through the panel's own
    // logged/​guarded push path rather than being reimplemented in the dialog.
    final andPush = await showMacosSheet<bool>(
      context: context,
      builder: (_) =>
          CommitDialog(repoPath: repoPath, stagedCount: stagedCount),
    );
    if (andPush == true && mounted) {
      await _push(followTags: ref.read(appSettingsProvider).pushFollowTags);
    }
  }

  /// Runs a mutating git op behind the [_busy] gate: no-ops if another mutation
  /// is already in flight, and toggles [_busy] so the toolbar/shortcuts reflect
  /// it. Returns whether the op actually ran and succeeded. Always refreshes
  /// the repo-scoped providers in `finally` — see the comment there.
  Future<bool> _guardedAction(Future<void> Function() op) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      return await runAction(context, op);
    } finally {
      // Refresh even when `op` failed: a thrown GitException is exactly how
      // GitService signals a merge/rebase/cherry-pick/revert conflict, and
      // pendingOpProvider (which follows statusProvider) needs to observe the
      // resulting in-progress state immediately so the conflict banner
      // appears, rather than waiting on some unrelated later refresh.
      // _refresh() is itself mounted-guarded, so this is safe even if the
      // widget was disposed mid-await.
      _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() op) async {
    await _guardedAction(op);
  }

  /// Runs a remote-sync operation, logging its command output to the output
  /// view and refreshing regardless of outcome (see the `finally` block).
  /// Failure output is logged too, then surfaced via the usual error dialog.
  /// Returns whether it succeeded, so a caller that also needs to update
  /// local state (e.g. clearing the selected conflict) can do so only once
  /// the operation actually completed.
  Future<bool> _runLogged(
    String title,
    Future<void> Function(OutputLogNotifier log) body,
  ) async {
    // Serialize with every other mutation (see [_busy]): a Pull/Push/Sync in
    // flight must not overlap a second one — they race on `.git/index.lock`.
    if (_busy) return false;
    setState(() => _busy = true);
    final log = ref.read(outputLogProvider.notifier);
    var ok = false;
    try {
      await body(log);
      ok = true;
    } on GitException catch (e) {
      log.logResult(title, e.result);
      if (mounted) await showErrorDialog(context, e.toString());
    } catch (e) {
      log.logError(title, e.toString());
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      // Refresh even on failure: a pull/push/sync that hits a conflict is
      // reported as a thrown GitException (that's how GitService signals
      // one), leaving a merge/rebase in progress — pendingOpProvider needs to
      // pick that up so the Repository panel's conflict banner shows up
      // immediately instead of after some unrelated later refresh.
      _refresh();
      if (mounted) setState(() => _busy = false);
    }
    return ok;
  }

  Future<void> _fetch() async {
    final git = ref.read(gitServiceProvider);
    await _runLogged(
      'git fetch --all --prune',
      (log) async =>
          log.logResult('git fetch --all --prune', await git.fetch(repoPath)),
    );
  }

  Future<void> _stashPush() async {
    final git = ref.read(gitServiceProvider);
    await _runLogged(
      'git stash push',
      (log) async =>
          log.logResult('git stash push', await git.stashPush(repoPath)),
    );
  }

  static String _pullLabel(PullMode mode) => switch (mode) {
    PullMode.ffOnly => 'git pull --ff-only',
    PullMode.rebase => 'git pull --rebase',
    PullMode.merge => 'git pull --no-rebase',
  };

  Future<void> _pull([PullMode mode = PullMode.ffOnly]) async {
    final git = ref.read(gitServiceProvider);
    final label = _pullLabel(mode);
    await _runLogged(label, (log) async {
      final before = await git.revParse(repoPath, 'HEAD');
      log.logResult(label, await git.pull(repoPath, mode: mode));
      await _logPulled(log, git, before);
    });
  }

  Future<void> _push({
    PushForce force = PushForce.none,
    bool setUpstream = false,
    bool followTags = false,
  }) async {
    // Pre-push guardrail: if the last-known status already shows the branch is
    // behind its upstream, a plain push will be rejected — offer to pull first
    // rather than surfacing a raw rejection. (A stale behind=0 just falls
    // through to the normal push, which still reports any rejection.)
    if (force == PushForce.none && !setUpstream) {
      final behind =
          ref.read(statusProvider(repoPath)).value?.branch.behind ?? 0;
      if (behind > 0) {
        final choice = await chooseAction<_PushChoice>(
          context,
          title: 'Remote has new commits',
          message:
              'The upstream branch is $behind commit(s) ahead of yours. '
              'Pushing now will be rejected — pull first?',
          primaryLabel: 'Pull, then Push',
          primaryValue: _PushChoice.pullThenPush,
          secondary: const [
            ('Push anyway', _PushChoice.pushAnyway),
            ('Cancel', _PushChoice.cancel),
          ],
        );
        // The confirm dialog spans an await — the widget can be gone (repo
        // switch, disconnect) by the time it resolves, before `ref`/`context`
        // are touched again.
        if (!mounted) return;
        if (choice == null || choice == _PushChoice.cancel) return;
        if (choice == _PushChoice.pullThenPush) {
          // _sync inlines pull-then-push and skips the push if the pull fails.
          return _sync(ref.read(appSettingsProvider).defaultPullMode);
        }
      }
    }
    if (!mounted) return;
    // A history-rewriting push is confirmed before it fires.
    if (force != PushForce.none) {
      final ok = await confirmAction(
        context,
        title: 'Force push',
        message: force == PushForce.withLease
            ? 'Force-push with lease? This overwrites the remote branch if no '
                  'one else has pushed since your last fetch.'
            : 'Force-push? This unconditionally overwrites the remote branch '
                  'and can destroy others\' commits.',
        confirmLabel: 'Force Push',
      );
      if (!ok || !mounted) return;
    }
    final git = ref.read(gitServiceProvider);
    final label = [
      'git push',
      if (force == PushForce.withLease) '--force-with-lease',
      if (force == PushForce.force) '--force',
      if (setUpstream) '-u',
      if (followTags) '--follow-tags',
    ].join(' ');
    await _runLogged(label, (log) async {
      // Capture the old remote tip before the push advances the tracking ref.
      final base = await git.revParse(repoPath, '@{upstream}');
      log.logResult(
        label,
        await git.push(
          repoPath,
          force: force,
          setUpstream: setUpstream,
          followTags: followTags,
        ),
      );
      await _logPushed(log, git, base);
    });
  }

  Future<void> _sync([PullMode mode = PullMode.ffOnly]) async {
    final git = ref.read(gitServiceProvider);
    final pullLabel = _pullLabel(mode);
    // Inlined pull-then-push (rather than git.sync) so each phase can report the
    // files it moved: the push base is @{upstream} *after* the pull advanced it.
    await _runLogged('git sync', (log) async {
      final before = await git.revParse(repoPath, 'HEAD');
      log.logResult(pullLabel, await git.pull(repoPath, mode: mode));
      await _logPulled(log, git, before);
      final pushBase = await git.revParse(repoPath, '@{upstream}');
      log.logResult('git push', await git.push(repoPath));
      await _logPushed(log, git, pushBase);
    });
  }

  // Logs the files a pull brought in (HEAD moved from [before] to now).
  Future<void> _logPulled(
    OutputLogNotifier log,
    GitService git,
    String? before,
  ) async {
    final after = await git.revParse(repoPath, 'HEAD');
    if (before != null && after != null && before != after) {
      log.logFiles(
        'Pulled',
        await git.changedFiles(repoPath, '$before..$after'),
      );
    }
  }

  // Logs the files a push published (from the old remote tip [base] to HEAD).
  Future<void> _logPushed(
    OutputLogNotifier log,
    GitService git,
    String? base,
  ) async {
    final head = await git.revParse(repoPath, 'HEAD');
    if (base != null && head != null && base != head) {
      log.logFiles('Pushed', await git.changedFiles(repoPath, '$base..$head'));
    }
  }

  Future<void> _discard(String path) async {
    final ok = await confirmAction(
      context,
      title: 'Discard changes',
      message:
          'Discard working-tree changes to "$path"? The content is '
          'snapshotted first — press ⌘Z to undo, or restore it later from '
          'the Recovery view.',
      confirmLabel: 'Discard',
    );
    if (ok) {
      await _run(() => ref.read(gitServiceProvider).discard(repoPath, path));
    }
  }

  /// Deletes a single untracked file from the working tree. Mirrors [_discard]
  /// (same confirmation pattern, same `_run`/`_guardedAction` gate so it can't
  /// race a concurrent mutation and refreshes statusProvider/repoStructureProvider
  /// afterward), but routes through [GitService.removeUntrackedFile] instead of
  /// `git restore` — there is no tracked history to fall back to for an
  /// untracked file, so this permanently deletes it rather than reverting it.
  Future<void> _discardUntracked(String path) async {
    final ok = await confirmAction(
      context,
      title: 'Delete untracked file',
      message:
          'Delete untracked file "$path"? Its content is snapshotted '
          'first — press ⌘Z to undo, or restore it later from the Recovery '
          'view.',
      confirmLabel: 'Delete',
    );
    if (ok) {
      await _run(
        () => ref.read(gitServiceProvider).removeUntrackedFile(repoPath, path),
      );
    }
  }

  Future<void> _resolve(String path, {required bool useOurs}) async {
    final git = ref.read(gitServiceProvider);
    if (await _guardedAction(
      () => git.resolveConflict(repoPath, path, useOurs: useOurs),
    )) {
      if (!mounted) return;
      _removeFromSelection(path);
    }
  }

  Future<void> _discardStaged(String path) async {
    final ok = await confirmAction(
      context,
      title: 'Discard staged changes',
      message:
          'Discard staged changes to "$path"? This restores it to its '
          'last-committed state (or removes it entirely if it was never '
          'committed). The content is snapshotted first — press ⌘Z to undo.',
      confirmLabel: 'Discard',
    );
    if (ok) {
      await _run(
        () => ref.read(gitServiceProvider).discardStaged(repoPath, path),
      );
    }
  }

  Future<void> _addToGitignore(String path) async {
    await _run(() => ref.read(gitServiceProvider).addToGitignore(repoPath, path));
  }

  // ---- Bulk (multi-select) file actions -------------------------------
  // Each calls the corresponding batch GitService method (one git invocation
  // covering the whole selection) inside one _guardedAction/_run — same
  // busy-gate and refresh as every single-file action. A resulting vanished
  // path (staged/discarded/deleted/resolved away) is dropped from the
  // selection generically by the statusProvider listener once the refresh
  // lands, same as the single-file actions rely on — except _resolveMany,
  // which (like _resolve) also clears immediately to avoid a stale-content
  // flash before that refresh completes.

  /// Caps a bulk confirmation's file list at [cap] entries so a 50-file
  /// selection doesn't produce an unreadably tall dialog.
  String _fileListSummary(List<String> paths, {int cap = 5}) {
    final shown = paths.take(cap).map((p) => '"$p"').join(', ');
    final extra = paths.length - cap;
    return extra > 0 ? '$shown, and $extra more' : shown;
  }

  Future<void> _stageMany(List<String> paths) async {
    await _run(() => ref.read(gitServiceProvider).stageMany(repoPath, paths));
  }

  Future<void> _unstageMany(List<String> paths) async {
    await _run(() => ref.read(gitServiceProvider).unstageMany(repoPath, paths));
  }

  Future<void> _discardMany(List<String> paths) async {
    final ok = await confirmAction(
      context,
      title: 'Discard changes',
      message:
          'Discard working-tree changes to ${_fileListSummary(paths)}? '
          'The content is snapshotted first — press ⌘Z to undo.',
      confirmLabel: 'Discard',
    );
    if (!ok) return;
    await _run(() => ref.read(gitServiceProvider).discardMany(repoPath, paths));
  }

  Future<void> _discardUntrackedMany(List<String> paths) async {
    final ok = await confirmAction(
      context,
      title: 'Delete untracked files',
      message:
          'Delete ${_fileListSummary(paths)}? Their content is snapshotted '
          'first — press ⌘Z to undo.',
      confirmLabel: 'Delete',
    );
    if (!ok) return;
    await _run(
      () => ref.read(gitServiceProvider).removeUntrackedFilesMany(repoPath, paths),
    );
  }

  Future<void> _discardStagedMany(List<String> paths) async {
    final ok = await confirmAction(
      context,
      title: 'Discard staged changes',
      message:
          'Discard staged changes to ${_fileListSummary(paths)}? The '
          'content is snapshotted first — press ⌘Z to undo.',
      confirmLabel: 'Discard',
    );
    if (!ok) return;
    await _run(
      () => ref.read(gitServiceProvider).discardStagedMany(repoPath, paths),
    );
  }

  Future<void> _addToGitignoreMany(List<String> paths) async {
    await _run(
      () => ref.read(gitServiceProvider).addToGitignoreMany(repoPath, paths),
    );
  }

  Future<void> _resolveMany(List<String> paths, {required bool useOurs}) async {
    if (await _guardedAction(
      () => ref
          .read(gitServiceProvider)
          .resolveConflictMany(repoPath, paths, useOurs: useOurs),
    )) {
      if (!mounted) return;
      for (final p in paths) {
        _removeFromSelection(p);
      }
    }
  }

  static String _pendingVerb(PendingOp op) => switch (op) {
    PendingOp.merge => 'Merge',
    PendingOp.cherryPick => 'Cherry-pick',
    PendingOp.revert => 'Revert',
    PendingOp.rebase => 'Rebase',
    PendingOp.none => '',
  };

  Future<void> _abortPending(PendingOp op) async {
    final verb = _pendingVerb(op);
    final ok = await confirmAction(
      context,
      title: 'Abort $verb',
      message:
          'Abort the in-progress ${verb.toLowerCase()} and discard its changes?',
      confirmLabel: 'Abort',
    );
    if (!ok || !mounted) return;
    final git = ref.read(gitServiceProvider);
    // Only clear the selected conflict once the abort actually succeeds —
    // clearing it upfront left the conflict panel stale (still showing a
    // conflict the abort never actually resolved) on failure, with no
    // rebuild to reflect that.
    if (await _guardedAction(
      () => switch (op) {
        PendingOp.merge => git.mergeAbort(repoPath),
        PendingOp.cherryPick => git.cherryPickAbort(repoPath),
        PendingOp.revert => git.revertAbort(repoPath),
        PendingOp.rebase => git.rebaseAbort(repoPath),
        PendingOp.none => Future<void>.value(),
      },
    )) {
      if (!mounted) return;
      _clearSelection();
    }
  }

  Future<void> _continueRebase() async {
    final ok = await _runLogged('git rebase --continue', (log) async {
      log.logResult(
        'git rebase --continue',
        await ref.read(gitServiceProvider).rebaseContinue(repoPath),
      );
    });
    // Same reasoning as _abortPending: only clear on success.
    if (ok && mounted) _clearSelection();
  }

  /// Banner shown while a merge/cherry-pick/revert/rebase is mid-flight (usually
  /// after a conflict), offering to continue (rebase) and/or abort.
  Widget _pendingBanner(BuildContext context, PendingOp op) {
    final typography = MacosTheme.of(context).typography;
    final verb = _pendingVerb(op);
    final hint = op == PendingOp.rebase
        ? '$verb in progress — resolve conflicts, then continue, or abort.'
        : '$verb in progress — resolve conflicts and commit, or abort.';
    return Container(
      color: MacosColors.systemOrangeColor.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.exclamationmark_triangle,
            size: 15,
            color: MacosColors.systemOrangeColor,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(hint, style: typography.caption1)),
          if (op == PendingOp.rebase) ...[
            PushButton(
              controlSize: ControlSize.small,
              onPressed: _continueRebase,
              child: const Text('Continue'),
            ),
            const SizedBox(width: 8),
          ],
          PushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: () => _abortPending(op),
            child: Text('Abort $verb'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Event-driven refresh: each coalesced remote-change tick re-fetches status.
    // Subscribing here also keeps the remote watcher alive while this view is
    // shown (it is auto-disposed when we stop listening).
    ref.listen(repoWatchProvider(repoPath), (previous, next) {
      final event = next.value;
      if (event == null) return;
      // Nearly every mutating action touches `.git/index`/HEAD/refs, so the
      // watcher fires shortly after this app's own explicit, immediate
      // _refresh() already invalidated status for the same change — skip
      // that redundant second fetch. A genuinely external change either
      // lands outside this window or is caught by the very next real tick.
      if (ref
          .read(ownMutationTrackerProvider)
          .isRecent(repoPath, event.at, _ownMutationSuppressWindow)) {
        return;
      }
      // An event-driven tick is a real filesystem change: record it so the
      // status memo can't dedupe a content-only edit to an already-modified
      // file (field-identical records, different bytes) — without this, the
      // diff/blame/conflict caches would keep serving pre-edit content.
      // Recorded even while the page is hidden (it's a local counter, no SSH
      // round-trip) so the didUpdateWidget re-sync on return can't be
      // swallowed by the memo either.
      if (event.mode == WatchMode.eventDriven) {
        noteWorktreeEdit(repoPath);
      }
      // While this page is hidden (another tab is up) don't fire a `git status`
      // round-trip on every tick — in polling mode that's a fetch every few
      // seconds against a repo the user isn't looking at. Keep the subscription
      // (so the watcher stays alive) but skip the refetch; didUpdateWidget
      // re-syncs once when the page becomes visible again.
      if (!widget.isActive) return;
      // Refresh status; the structure tree, status overlay, and sequencer
      // state all follow from it (the tree only re-fetches when its shape
      // changes — see repoStructureProvider).
      ref.invalidate(statusProvider(repoPath));
    });
    // If the selected conflict was resolved outside this session (another
    // terminal, a `git rebase --continue` run elsewhere) the file list
    // correctly drops it on the next status refresh, but the conflict panel
    // itself has no reason to rebuild on its own — clear the selection so it
    // doesn't keep showing stale merge-marker content indefinitely.
    ref.listen(statusProvider(repoPath), (previous, next) {
      // Warm the diff cache for the files most likely to be clicked next, so
      // opening one renders from RAM instead of waiting a round trip — see
      // _prefetchDiffs.
      _prefetchDiffs(next.value);
      final status = next.value;
      final kind = _selectionKind;
      if (status == null || kind == null) return;
      // If a selected file left the working tree externally (committed,
      // discarded, or a conflict resolved in another terminal), its path is
      // no longer in the file list — drop it from the selection so the panel
      // stops requesting a diff/conflict-content for a file git no longer
      // reports. Applied per-path (not just "clear everything") so the rest
      // of a multi-selection survives one member disappearing.
      final stillPresent = kind == _SectionKind.conflict
          ? status.conflicted.map((f) => f.path).toSet()
          : status.files.map((f) => f.path).toSet();
      final pruned = _selectedPaths.intersection(stillPresent);
      if (pruned.length != _selectedPaths.length) {
        setState(() {
          _selectedPaths = pruned;
          if (_selectedPaths.isEmpty) _selectionKind = null;
        });
      }
    });
    final pending = ref.watch(pendingOpProvider(repoPath)).value;
    // Keep the background auto-fetch timer alive while this panel is shown.
    ref.watch(autoFetchProvider);
    final watch = ref.watch(repoWatchProvider(repoPath));
    final watchMode = watch.value?.mode;
    final statusAsync = ref.watch(statusProvider(repoPath));
    // Null while refs are still loading — treated as "unknown" (not "no
    // remote") so the header doesn't flash the "No remote detected" label
    // before the first fetch resolves.
    final refs = ref.watch(refsProvider(repoPath)).value;
    final typography = MacosTheme.of(context).typography;
    final sessionWarning = ref.watch(connectionProvider.select((c) => c.warning));
    final outputVisible = ref.watch(outputLogProvider.select((s) => s.visible));
    final fileVisible = ref.watch(fileViewVisibleProvider);

    final status = statusAsync.value;
    final selected = _selected;
    final keymap = ref.watch(keymapProvider);
    final shortcuts = widget.isActive && !_busy
        ? resolveShortcuts(keymap, {
            'repository.fetch': _fetch,
            'repository.push': () =>
                _push(followTags: ref.read(appSettingsProvider).pushFollowTags),
            'repository.pull': () =>
                _pull(ref.read(appSettingsProvider).defaultPullMode),
            'repository.stash': _stashPush,
            'repository.sync': _sync,
            'repository.forcePush': () => _push(force: PushForce.withLease),
            'repository.stageAll':
                status != null &&
                    (status.unstaged.isNotEmpty || status.untracked.isNotEmpty)
                ? _stageAll
                : null,
            // Diff-view toggles: only meaningful while a file's diff is showing,
            // so they fall through (null) when nothing is selected.
            'repository.toggleSplitDiff': selected == null
                ? null
                : () => setState(() => _diffSplit = !_diffSplit),
            'repository.toggleIgnoreWhitespace': selected == null
                ? null
                : () => setState(() => _diffIgnoreWs = !_diffIgnoreWs),
            'repository.toggleExpandContext': selected == null
                ? null
                : () => setState(() => _diffExpandContext = !_diffExpandContext),
            'repository.toggleStage': selected == null
                ? null
                : () => selected.staged
                      ? _unstage(selected.path)
                      : _stage(selected.path),
            // Discard is only offered for unstaged rows elsewhere in this view
            // (the "discardable" rows: unstaged tracked changes and untracked
            // files) — matched here so the shortcut can't silently discard a
            // staged selection. Untracked routes to the delete-file action
            // instead of `git restore`, same split as the file-list row below.
            'repository.discard': selected == null || selected.staged
                ? null
                : () => selected.untracked
                      ? _discardUntracked(selected.path)
                      : _discard(selected.path),
            'repository.focusCommit': status != null && status.staged.isNotEmpty
                ? () => _openCommitDialog(status.staged.length)
                : null,
          })
        : const <ShortcutActivator, VoidCallback>{};

    return PanelShortcuts(
      bindings: shortcuts,
      child: LayoutBuilder(
        builder: (context, constraints) {
        final statusArea = Expanded(
          child: statusAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '$err',
                  style: typography.body.copyWith(
                    color: MacosColors.systemRedColor,
                  ),
                ),
              ),
            ),
            data: (status) => _body(context, status),
          ),
        );
        // Pane priority: a right pane (the file view) is the full-height "3rd
        // panel" and takes precedence over any horizontal pane. Horizontal
        // panes — including the output view — live inside the center "main"
        // column, so they're clamped to its width and never extend under (or
        // clip) the right pane.
        final centerColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (sessionWarning != null) _warningBanner(context, sessionWarning),
            _header(context, status, watchMode, refs),
            if (pending != null && pending != PendingOp.none)
              _pendingBanner(context, pending),
            statusArea,
            if (status != null && !status.isClean) _commitBar(context, status),
            if (outputVisible) OutputView(maxHeight: constraints.maxHeight),
          ],
        );
        return Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: centerColumn),
                if (fileVisible)
                  FileView(
                    maxWidth: constraints.maxWidth,
                    repoPath: repoPath,
                    onOpenFile: _openFileFromTree,
                  ),
              ],
            ),
            if (_popout && selected != null)
              DiffPopoutWindow(
                repoPath: repoPath,
                path: selected.path,
                staged: selected.staged,
                untracked: selected.untracked,
                initialSplit: _diffSplit,
                initialIgnoreWs: _diffIgnoreWs,
                contextLines: _diffCtx,
                bounds: Size(constraints.maxWidth, constraints.maxHeight),
                onHunkAction: _applyHunk,
                onClose: () => setState(() => _popout = false),
              ),
          ],
        );
      },
      ),
    );
  }

  /// Opens a tree-selected file's diff in the existing diff panel.
  void _openFileFromTree(
    String path, {
    required bool staged,
    required bool untracked,
  }) {
    setState(() {
      _selectionKind = untracked
          ? _SectionKind.untracked
          : staged
          ? _SectionKind.staged
          : _SectionKind.unstaged;
      _selectedPaths = {path};
      _selectionAnchor = path;
    });
  }

  Widget _commitBar(BuildContext context, GitStatus status) {
    final stagedCount = status.staged.length;
    // "Active" (accent-colored) while there's something left to stage; once
    // everything is staged it reverts to the same secondary look it always had.
    final hasUnstaged = stagedCount < status.files.length;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Text(
            stagedCount > 0 ? '$stagedCount staged' : 'Stage files to commit',
            style: MacosTheme.of(
              context,
            ).typography.caption1.copyWith(color: MacosColors.systemGrayColor),
          ),
          const Spacer(),
          PushButton(
            controlSize: ControlSize.large,
            secondary: !hasUnstaged,
            onPressed: _stageAll,
            child: const Text('Stage All'),
          ),
          const SizedBox(width: 8),
          PushButton(
            controlSize: ControlSize.large,
            // Same convention as "Stage All": grey when idle, blue once
            // there's something to act on.
            secondary: stagedCount == 0,
            onPressed: stagedCount > 0
                ? () => _openCommitDialog(stagedCount)
                : null,
            child: const Text('Commit…'),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, GitStatus status) {
    final list = _fileList(context, status);
    // Popped out: the diff moved into the floating window, so the file list
    // gets its full width back instead of splitting the row with it.
    final Widget? panel = _popout
        ? null
        : _isMultiSelect
        ? _multiSelectPanel(context)
        : _selectedConflict != null
        ? _conflictPanel(context, _selectedConflict!)
        : _selected != null
        ? _diffPanel(context)
        : null;
    if (panel == null) return list;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 2, child: list),
        Container(width: 1, color: MacosColors.separatorColor),
        Expanded(flex: 3, child: panel),
      ],
    );
  }

  /// Shown in place of the diff/conflict panel whenever 2+ files are
  /// selected — full multi-file diff rendering is a separate, bigger
  /// feature; for now this just confirms the selection while bulk actions
  /// (stage/unstage/discard N files, etc.) are reachable from the right-click
  /// menu on the selected rows.
  Widget _multiSelectPanel(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final noun = _selectionKind == _SectionKind.conflict
        ? 'conflicted files'
        : 'files';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              const Spacer(),
              ToolIconButton(
                icon: CupertinoIcons.xmark,
                tooltip: 'Close',
                size: 15,
                onPressed: _clearSelection,
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: Center(
            child: Text(
              '${_selectedPaths.length} $noun selected',
              style: typography.body.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _conflictPanel(BuildContext context, String path) {
    final contentAsync = ref.watch(conflictFileProvider((repoPath, path)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  path,
                  style: MacosTheme.of(context).typography.caption1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PushButton(
                controlSize: ControlSize.small,
                secondary: true,
                onPressed: () => _resolve(path, useOurs: true),
                child: const Text('Use Ours'),
              ),
              const SizedBox(width: 6),
              PushButton(
                controlSize: ControlSize.small,
                secondary: true,
                onPressed: () => _resolve(path, useOurs: false),
                child: const Text('Use Theirs'),
              ),
              const SizedBox(width: 6),
              ToolIconButton(
                icon: CupertinoIcons.xmark,
                tooltip: 'Close',
                size: 15,
                onPressed: _clearSelection,
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: contentAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '$err',
                  style: MacosTheme.of(
                    context,
                  ).typography.body.copyWith(color: MacosColors.systemRedColor),
                ),
              ),
            ),
            data: (content) => ConflictView(content: content),
          ),
        ),
      ],
    );
  }

  Widget _diffPanel(BuildContext context) {
    final (:path, :staged, :untracked) = _selected!;
    // Untracked files have no diff — show their contents as an additions diff.
    final diffAsync = untracked
        ? ref.watch(untrackedDiffProvider((repoPath, path)))
        : ref.watch(
            fileDiffProvider((repoPath, path, staged, _diffIgnoreWs, _diffCtx)),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  path,
                  style: MacosTheme.of(context).typography.caption1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Diff-viewer ergonomics: side-by-side, hide whitespace, expand
              // context. Active toggles are tinted blue; inactive are gray.
              _diffToggle(
                icon: CupertinoIcons.square_split_2x1,
                tooltip: 'Side-by-side',
                active: _diffSplit,
                onPressed: () => setState(() => _diffSplit = !_diffSplit),
              ),
              _diffToggle(
                icon: CupertinoIcons.paintbrush,
                tooltip: 'Ignore whitespace',
                active: _diffIgnoreWs,
                onPressed: () => setState(() => _diffIgnoreWs = !_diffIgnoreWs),
              ),
              _diffToggle(
                icon: CupertinoIcons.arrow_up_arrow_down,
                tooltip: 'Expand context',
                active: _diffExpandContext,
                onPressed: () =>
                    setState(() => _diffExpandContext = !_diffExpandContext),
              ),
              const SizedBox(width: 4),
              ToolIconButton(
                icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                tooltip: 'Open diff in a larger window',
                size: 15,
                color: MacosColors.systemGrayColor,
                onPressed: () => setState(() => _popout = true),
              ),
              const SizedBox(width: 4),
              ToolIconButton(
                icon: CupertinoIcons.xmark,
                tooltip: 'Close diff',
                size: 15,
                color: MacosColors.systemGrayColor,
                onPressed: _clearSelection,
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '$err',
                  style: MacosTheme.of(
                    context,
                  ).typography.body.copyWith(color: MacosColors.systemRedColor),
                ),
              ),
            ),
            // Per-hunk staging is available only for the unified worktree/index
            // diff of a tracked file. Split view is read-only, and a `-w` diff
            // isn't a valid apply patch — both fall back to a read-only render.
            data: (diff) {
              if (_diffSplit) return SplitDiffView(diff: diff);
              if (untracked || _diffIgnoreWs) return DiffView(diff: diff);
              return HunkDiffView(
                diff: diff,
                staged: staged,
                onAction: _applyHunk,
              );
            },
          ),
        ),
      ],
    );
  }

  /// A diff-viewer ergonomics toggle. Tinted with the same accent blue as the
  /// toolbar's other menu icons when [active], gray otherwise.
  Widget _diffToggle({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onPressed,
  }) => ToolIconButton(
    icon: icon,
    tooltip: tooltip,
    size: 15,
    color: active
        ? MacosTheme.of(context).iconTheme.color
        : MacosColors.systemGrayColor,
    onPressed: onPressed,
  );

  /// Stages / unstages / discards a single hunk by rebuilding a one-hunk patch
  /// and feeding it to `git apply`. Refreshes status and the *specific* diff key
  /// so the pane reflects the change immediately.
  Future<void> _applyHunk(
    DiffFile file,
    DiffHunk hunk,
    HunkAction action,
  ) async {
    if (_selected == null) return;
    final git = ref.read(gitServiceProvider);
    final patch = buildHunkPatch(file, hunk);

    if (action == HunkAction.discard) {
      final ok = await confirmAction(
        context,
        title: 'Discard hunk',
        message:
            'Discard this hunk from the working tree? This cannot be '
            'undone.',
        confirmLabel: 'Discard',
      );
      if (!ok) return;
    }
    if (!mounted) return;

    await _guardedAction(() {
      switch (action) {
        case HunkAction.stage:
          return git.applyPatch(repoPath, patch, cached: true, reverse: false);
        case HunkAction.unstage:
          return git.applyPatch(repoPath, patch, cached: true, reverse: true);
        case HunkAction.discard:
          return git.applyPatch(repoPath, patch, cached: false, reverse: true);
      }
    });
    // _guardedAction's `finally` now runs _refresh() unconditionally (success
    // or failure) — mounted-guarded, marking the own-mutation (so the
    // watcher's echo tick is suppressed rather than triggering a redundant
    // refetch) and invalidating status plus the selected file's diff key.
  }

  Widget _warningBanner(BuildContext context, String message) {
    return Container(
      width: double.infinity,
      color: MacosColors.systemOrangeColor.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.exclamationmark_triangle,
            size: 14,
            color: MacosColors.systemOrangeColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: MacosTheme.of(context).typography.caption1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    GitStatus? status,
    WatchMode? watchMode,
    List<GitRef>? refs,
  ) {
    final typography = MacosTheme.of(context).typography;
    final branch = status?.branch;
    // Repo-level fact (any remote-tracking ref at all), not per-branch
    // upstream tracking — a repo can have zero remotes configured, or have
    // one configured but never fetched, and either way this is what "No
    // remote detected" means here. Works identically for a local repo that
    // was simply never pushed anywhere and an SSH repo missing an `origin`.
    // Null (still loading) is treated as "has a remote" so the label doesn't
    // flash on before the first fetch resolves.
    final hasRemote = refs == null || refs.any((r) => r.isRemote);
    // Network actions need a remote — disable them (not just the _busy gate)
    // when none is detected, so they can't be clicked into a guaranteed error.
    // Matches the "No remote detected" label rendered below.
    final remoteDisabled = _busy || !hasRemote;
    final label = branch == null
        ? repoPath
        : branch.isDetached
        ? '(detached)'
        : branch.head ?? repoPath;
    final (dotColor, watchHint) = switch (watchMode) {
      WatchMode.eventDriven => (
        MacosColors.systemGreenColor,
        'Live file watcher',
      ),
      WatchMode.polling => (
        MacosColors.systemOrangeColor,
        'Polling for changes (watcher unavailable)',
      ),
      WatchMode.stopped ||
      null => (MacosColors.systemGrayColor, 'Watcher stopped'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          MacosTooltip(
            message: watchHint,
            child: MacosIcon(
              CupertinoIcons.circle_fill,
              size: 8,
              color: dotColor,
            ),
          ),
          const SizedBox(width: 8),
          const MacosIcon(CupertinoIcons.arrow_branch, size: 18),
          const SizedBox(width: 6),
          Text(label, style: typography.headline),
          if (branch != null && branch.hasUpstream) ...[
            const SizedBox(width: 8),
            Text(
              '↑${branch.ahead} ↓${branch.behind}',
              style: typography.caption1,
            ),
          ],
          if (!hasRemote) ...[
            const SizedBox(width: 8),
            Text(
              'No remote detected',
              style: typography.caption1.copyWith(
                color: MacosColors.systemYellowColor,
              ),
            ),
          ],
          const Spacer(),
          _toolButton(
            CupertinoIcons.cloud_download,
            'Fetch',
            remoteDisabled ? null : _fetch,
          ),
          _toolButton(
            CupertinoIcons.arrow_down_circle,
            'Pull',
            remoteDisabled
                ? null
                : () => _pull(ref.read(appSettingsProvider).defaultPullMode),
            color: _needsPull(branch) ? MacosColors.systemGreenColor : null,
          ),
          _toolButton(
            CupertinoIcons.arrow_up_circle,
            'Push',
            remoteDisabled
                ? null
                : () => _push(
                    followTags: ref.read(appSettingsProvider).pushFollowTags,
                  ),
            color: _needsPush(branch) ? MacosColors.systemGreenColor : null,
          ),
          _toolButton(
            CupertinoIcons.arrow_2_circlepath,
            'Sync (pull then push)',
            remoteDisabled
                ? null
                : () => _sync(ref.read(appSettingsProvider).defaultPullMode),
            color: _needsPush(branch) && _needsPull(branch)
                ? MacosColors.systemGreenColor
                : null,
          ),
          _toolButton(
            CupertinoIcons.tray_arrow_down,
            'Stash',
            _busy ? null : _stashPush,
          ),
          const SizedBox(width: 2),
          ToolIconButton(
            icon: CupertinoIcons.refresh,
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
          const SizedBox(width: 2),
          ToolIconButton(
            icon: CupertinoIcons.gear,
            tooltip: 'Settings',
            onPressed: () => showMacosSheet<void>(
              context: context,
              builder: (_) => const EscapeDismissible(child: SettingsSheet()),
            ),
          ),
          const SizedBox(width: 6),
          // System-grey to match the History toolbar's overflow menu, distinct
          // from the accent-tinted action icons to its left.
          MacosPulldownButtonTheme(
            data: MacosPulldownButtonTheme.of(
              context,
            ).copyWith(iconColor: MacosColors.systemGrayColor),
            child: MacosPulldownButton(
              // Convention: toolbar menus use the "hamburger" (three horizontal
              // lines) glyph — the universally recognized menu affordance.
              icon: CupertinoIcons.line_horizontal_3,
              items: [
                MacosPulldownMenuItem(
                  title: const Text('Pull (rebase)'),
                  onTap: () => _pull(PullMode.rebase),
                ),
                MacosPulldownMenuItem(
                  title: const Text('Pull (merge)'),
                  onTap: () => _pull(PullMode.merge),
                ),
                const MacosPulldownMenuDivider(),
                MacosPulldownMenuItem(
                  title: const Text('Push (set upstream)'),
                  onTap: () => _push(setUpstream: true),
                ),
                MacosPulldownMenuItem(
                  title: const Text('Push tags'),
                  onTap: () => _push(followTags: true),
                ),
                MacosPulldownMenuItem(
                  title: const Text('Force push (with lease)'),
                  onTap: () => _push(force: PushForce.withLease),
                ),
                MacosPulldownMenuItem(
                  title: const Text('Force push'),
                  onTap: () => _push(force: PushForce.force),
                ),
                const MacosPulldownMenuDivider(),
                MacosPulldownMenuItem(
                  title: const Text('Sync (pull then push)'),
                  onTap: () =>
                      _sync(ref.read(appSettingsProvider).defaultPullMode),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolButton(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    Color? color,
  }) => ToolIconButton(
    icon: icon,
    tooltip: tooltip,
    size: 18,
    color: color,
    onPressed: onPressed,
  );

  // Whether the Push/Sync icons should flip to green — a commit sitting
  // locally, unpushed, with nothing else needed. No upstream means there's
  // nothing to compare against, so no cue either way.
  bool _needsPush(GitBranchInfo? branch) =>
      branch != null && branch.hasUpstream && branch.ahead > 0;

  // Same, for Pull/Sync: the upstream has commits this branch doesn't.
  bool _needsPull(GitBranchInfo? branch) =>
      branch != null && branch.hasUpstream && branch.behind > 0;

  List<_StatusRow> _statusRows(GitStatus status) {
    if (identical(status, _rowsForStatus)) return _rows;
    final rows = <_StatusRow>[];
    void addSection(
      String title,
      List<GitFileStatus> files, {
      required bool staged,
      bool discardable = false,
      bool conflict = false,
    }) {
      if (files.isEmpty) return;
      rows.add(_HeaderRow(title, files.length, conflict: conflict));
      for (final f in files) {
        rows.add(
          _FileRow(
            f,
            staged: staged,
            discardable: discardable,
            conflict: conflict,
          ),
        );
      }
    }

    addSection('Conflicts', status.conflicted, staged: false, conflict: true);
    addSection('Staged', status.staged, staged: true);
    addSection('Changes', status.unstaged, staged: false, discardable: true);
    // Untracked files are "discardable" too — see _statusRow, which routes
    // the discard action to _discardUntracked (delete) instead of _discard
    // (restore) for these rows, since there's no tracked history to restore.
    addSection('Untracked', status.untracked, staged: false, discardable: true);
    _rowsForStatus = status;
    _rows = rows;
    return rows;
  }

  Widget _fileList(BuildContext context, GitStatus status) {
    if (status.isClean) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/MG-RKT-icon.png',
                width: 200,
                height: 200,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '|| The working tree is clean ||',
              // Terminal-styled: same monospace family as the output view's
              // log text, phosphor green, sized a touch larger than body text
              // so its width roughly matches the icon above it.
              style: MacosTheme.of(context).typography.body.copyWith(
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['SF Mono', 'Consolas', 'monospace'],
                color: const Color(0xFF33FF33),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    final rows = _statusRows(status);
    return Focus(
      focusNode: _listFocus,
      onKeyEvent: _onListKey,
      child: ListView.builder(
        controller: _listScroll,
        itemCount: rows.length,
        itemBuilder: (context, index) => _statusRow(context, rows[index], rows),
      ),
    );
  }

  _SectionKind _kindOfFileRow(_FileRow row) => row.conflict
      ? _SectionKind.conflict
      : row.staged
      ? _SectionKind.staged
      : row.file.isUntracked
      ? _SectionKind.untracked
      : _SectionKind.unstaged;

  /// The contiguous run of paths (within [kind]'s section, in on-screen
  /// order) between [anchor] and [target], inclusive of both — the result of
  /// a shift-click range-select. Falls back to just [target] if either
  /// endpoint isn't in the section (e.g. the anchor's file was since staged
  /// out of an unstaged-section anchor).
  Set<String> _rangeBetween(
    List<_StatusRow> rows,
    _SectionKind kind,
    String anchor,
    String target,
  ) {
    final paths = [
      for (final r in rows)
        if (r is _FileRow && _kindOfFileRow(r) == kind) r.file.path,
    ];
    final i = paths.indexOf(anchor);
    final j = paths.indexOf(target);
    if (i == -1 || j == -1) return {target};
    final lo = i < j ? i : j;
    final hi = i < j ? j : i;
    return paths.sublist(lo, hi + 1).toSet();
  }

  /// Handles a plain click, cmd-click, or shift-click on a file/conflict row —
  /// the macOS list-selection conventions: plain click replaces the
  /// selection; cmd-click toggles this row in/out of it; shift-click extends
  /// a contiguous range from the anchor. Clicking into a different section
  /// than the current selection always replaces it — see the [_SectionKind]
  /// doc comment for why selections don't span sections.
  void _handleRowTap(List<_StatusRow> rows, String path, _SectionKind kind) {
    final keys = HardwareKeyboard.instance;
    final meta = keys.isMetaPressed;
    final shift = keys.isShiftPressed;
    setState(() {
      if (meta && _selectionKind == kind) {
        if (_selectedPaths.contains(path)) {
          _selectedPaths = {..._selectedPaths}..remove(path);
          if (_selectedPaths.isEmpty) _selectionKind = null;
        } else {
          _selectedPaths = {..._selectedPaths, path};
        }
        _selectionAnchor = path;
      } else if (shift && _selectionKind == kind && _selectionAnchor != null) {
        _selectedPaths = _rangeBetween(rows, kind, _selectionAnchor!, path);
        // Anchor is deliberately left in place — repeated shift-clicks
        // extend/contract from the same fixed end, matching Finder.
      } else {
        _selectionKind = kind;
        _selectedPaths = {path};
        _selectionAnchor = path;
      }
      // Popout only ever shows a single non-conflict file's diff; drop it
      // once the selection no longer looks like that (a conflict, none, or
      // several files) rather than leaving it showing a stale file.
      if (kind == _SectionKind.conflict || _selectedPaths.length != 1) {
        _popout = false;
      }
    });
  }

  String _absolutePath(String path) => '$repoPath/$path';

  /// The currently-selected paths within [kind]'s section, in on-screen
  /// (top-to-bottom) order — used both for the bulk confirm dialogs' file
  /// list and for a stable Copy Path/Copy Relative Path ordering.
  List<String> _orderedSelectedPaths(List<_StatusRow> rows, _SectionKind kind) {
    final selected = _selectedPaths;
    return [
      for (final r in rows)
        if (r is _FileRow &&
            _kindOfFileRow(r) == kind &&
            selected.contains(r.file.path))
          r.file.path,
    ];
  }

  /// Handles a right-click on a file/conflict row: if the click landed
  /// outside the current selection, it collapses to just that row first —
  /// same as Finder, the menu always acts on what ends up selected, not
  /// whatever was selected before the click. Then shows the menu for
  /// whichever selection results.
  void _handleRowSecondaryTap(
    List<_StatusRow> rows,
    String path,
    _SectionKind kind,
    Offset globalPosition,
  ) {
    if (_selectionKind != kind || !_selectedPaths.contains(path)) {
      setState(() {
        _selectionKind = kind;
        _selectedPaths = {path};
        _selectionAnchor = path;
        if (kind == _SectionKind.conflict) _popout = false;
      });
    }
    final paths = _orderedSelectedPaths(rows, kind);
    _contextMenu.show(context, globalPosition, _buildMenuEntries(kind, paths));
  }

  /// Builds the right-click menu for [paths] (1 or more) within [kind]'s
  /// section: the section-specific actions (mirroring every action already
  /// reachable via the row's icon buttons/toolbar, per-file or bulk), then a
  /// common block (copy path/relative path, and — local connections only,
  /// since these need this machine's own Finder/LaunchServices — reveal in
  /// Finder and open file).
  List<ContextMenuEntry> _buildMenuEntries(_SectionKind kind, List<String> paths) {
    final many = paths.length > 1;
    final n = paths.length;
    final entries = <ContextMenuEntry>[];

    switch (kind) {
      case _SectionKind.untracked:
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.plus_circle,
            label: many ? 'Stage $n Files' : 'Stage',
            onTap: () =>
                many ? _stageMany(paths) : _stage(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.eye_slash,
            label: many ? 'Add $n Files to .gitignore' : 'Add to .gitignore',
            onTap: () => many
                ? _addToGitignoreMany(paths)
                : _addToGitignore(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.trash,
            label: many ? 'Delete $n Files' : 'Delete Untracked File',
            onTap: () => many
                ? _discardUntrackedMany(paths)
                : _discardUntracked(paths.single),
          ),
        ]);
      case _SectionKind.unstaged:
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.plus_circle,
            label: many ? 'Stage $n Files' : 'Stage',
            onTap: () =>
                many ? _stageMany(paths) : _stage(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.arrow_uturn_left,
            label: many ? 'Discard Changes in $n Files' : 'Discard Changes',
            onTap: () =>
                many ? _discardMany(paths) : _discard(paths.single),
          ),
          if (!many)
            ContextMenuItem(
              icon: CupertinoIcons.person_crop_rectangle,
              label: 'Blame',
              onTap: () => showMacosSheet<void>(
                context: context,
                builder: (_) => EscapeDismissible(
                  child: BlameSheet(repoPath: repoPath, path: paths.single),
                ),
              ),
            ),
        ]);
      case _SectionKind.staged:
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.minus_circle,
            label: many ? 'Unstage $n Files' : 'Unstage',
            onTap: () =>
                many ? _unstageMany(paths) : _unstage(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.arrow_uturn_left,
            label: many
                ? 'Discard Staged Changes in $n Files'
                : 'Discard Staged Changes',
            onTap: () => many
                ? _discardStagedMany(paths)
                : _discardStaged(paths.single),
          ),
        ]);
      case _SectionKind.conflict:
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.person_crop_circle,
            label: many ? 'Resolve $n Using Ours' : 'Resolve Using Ours',
            onTap: () => many
                ? _resolveMany(paths, useOurs: true)
                : _resolve(paths.single, useOurs: true),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.person_crop_circle_fill,
            label: many ? 'Resolve $n Using Theirs' : 'Resolve Using Theirs',
            onTap: () => many
                ? _resolveMany(paths, useOurs: false)
                : _resolve(paths.single, useOurs: false),
          ),
        ]);
    }

    entries.add(const ContextMenuDivider());
    entries.add(
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_clipboard,
        label: many ? 'Copy $n Relative Paths' : 'Copy Relative Path',
        onTap: () => copyToClipboard(paths.join('\n')),
      ),
    );
    entries.add(
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_clipboard_fill,
        label: many ? 'Copy $n Paths' : 'Copy Path',
        onTap: () =>
            copyToClipboard(paths.map(_absolutePath).join('\n')),
      ),
    );
    // Reveal/open need this machine's own Finder/LaunchServices — meaningless
    // (and pointed at the wrong filesystem) for an SSH-backed connection,
    // whose files live on the remote host.
    if (ref.read(connectionProvider).isLocal) {
      if (!many) {
        entries.add(
          ContextMenuItem(
            icon: CupertinoIcons.folder,
            label: 'Reveal in Finder',
            onTap: () => revealInFinder(_absolutePath(paths.single)),
          ),
        );
      }
      entries.add(
        ContextMenuItem(
          icon: CupertinoIcons.square_arrow_up,
          label: many ? 'Open $n Files' : 'Open File',
          onTap: () => openFiles(paths.map(_absolutePath).toList()),
        ),
      );
    }
    return entries;
  }

  Widget _statusRow(
    BuildContext context,
    _StatusRow row,
    List<_StatusRow> rows,
  ) {
    final typography = MacosTheme.of(context).typography;
    if (row is _HeaderRow) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          '${row.title} (${row.count})',
          style: typography.caption1.copyWith(
            fontWeight: FontWeight.bold,
            color: row.conflict ? MacosColors.systemRedColor : null,
          ),
        ),
      );
    }

    // Only _HeaderRow and _FileRow exist and the header case returned above;
    // promote to _FileRow for the file-row rendering below.
    row as _FileRow;
    final file = row.file;
    if (row.conflict) {
      return KeyedSubtree(
        key: _rowKeyFor(file.path, _SectionKind.conflict),
        child: GestureDetector(
        onTap: () {
          _listFocus.requestFocus();
          _handleRowTap(rows, file.path, _SectionKind.conflict);
        },
        onSecondaryTapUp: (d) => _handleRowSecondaryTap(
          rows,
          file.path,
          _SectionKind.conflict,
          d.globalPosition,
        ),
        child: Container(
          color: _selectedPaths.contains(file.path)
              ? MacosColors.systemRedColor.withValues(alpha: 0.12)
              : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          child: Row(
            children: [
              const MacosIcon(
                CupertinoIcons.exclamationmark_triangle,
                size: 15,
                color: MacosColors.systemRedColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  file.path,
                  style: typography.body,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ToolIconButton(
                icon: CupertinoIcons.person_crop_circle,
                tooltip: 'Resolve using ours',
                size: 16,
                onPressed: () => _resolve(file.path, useOurs: true),
              ),
              ToolIconButton(
                icon: CupertinoIcons.person_crop_circle_fill,
                tooltip: 'Resolve using theirs',
                size: 16,
                onPressed: () => _resolve(file.path, useOurs: false),
              ),
            ],
          ),
        ),
        ),
      );
    }

    final staged = row.staged;
    final kind = _kindOfFileRow(row);
    return KeyedSubtree(
      key: _rowKeyFor(file.path, kind),
      child: GestureDetector(
      onTap: () {
        _listFocus.requestFocus();
        _handleRowTap(rows, file.path, kind);
      },
      onSecondaryTapUp: (d) =>
          _handleRowSecondaryTap(rows, file.path, kind, d.globalPosition),
      child: Container(
        color: _selectedPaths.contains(file.path)
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Align(
                alignment: Alignment.centerLeft,
                child: GitStatusBadge(file, staged: staged),
              ),
            ),
            Expanded(
              child: Text(
                file.oldPath != null
                    ? '${file.oldPath} → ${file.path}'
                    : file.path,
                style: typography.body,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (row.discardable)
              ToolIconButton(
                // An untracked file has nothing tracked to revert to — delete
                // it outright (trash icon) rather than "discard" (revert icon).
                icon: file.isUntracked
                    ? CupertinoIcons.trash
                    : CupertinoIcons.arrow_uturn_left,
                tooltip: file.isUntracked
                    ? 'Delete untracked file'
                    : 'Discard changes',
                size: 16,
                color: MacosColors.systemRedColor,
                onPressed: () => file.isUntracked
                    ? _discardUntracked(file.path)
                    : _discard(file.path),
              ),
            ToolIconButton(
              icon: staged
                  ? CupertinoIcons.minus_circle
                  : CupertinoIcons.plus_circle,
              tooltip: staged ? 'Unstage' : 'Stage',
              size: 17,
              color: staged
                  ? MacosColors.systemOrangeColor
                  : MacosColors.systemGreenColor,
              onPressed: () => staged ? _unstage(file.path) : _stage(file.path),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// A row in the status file list: either a section header or a file. Sealed so
/// [_statusRow] switches exhaustively and each variant carries only the fields
/// it actually has — no nullable union with `!` force-unwraps.
sealed class _StatusRow {
  const _StatusRow();
}

/// A section header row ("Staged (3)", "Conflicts (1)", …).
class _HeaderRow extends _StatusRow {
  final String title;
  final int count;
  final bool conflict;
  const _HeaderRow(this.title, this.count, {this.conflict = false});
}

/// A single file row under a section.
class _FileRow extends _StatusRow {
  final GitFileStatus file;
  final bool staged;
  final bool discardable;
  final bool conflict;
  const _FileRow(
    this.file, {
    required this.staged,
    this.discardable = false,
    this.conflict = false,
  });
}
