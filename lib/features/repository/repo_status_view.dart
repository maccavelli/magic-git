import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/operation_activity.dart';
import '../../core/git/git_service.dart';
import '../../core/git/unified_diff.dart';
import '../../core/git/watch_event.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import '../../core/ssh/ssh_command_executor.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/display_error.dart';
import '../../core/utils/file_actions.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/busy_action.dart';
import '../common/buttons.dart';
import '../common/context_menu.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/image_diff_view.dart';
import '../common/inline_action_button.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/repository_context.dart';
import '../common/repository_context_bar.dart';
import '../common/repository_workspace_scaffold.dart';
import '../common/resizable_master_detail.dart';
import '../common/split_diff_view.dart';
import '../common/status_style.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../common/workspace_navigation.dart';
import '../dnd/deselect.dart';
import '../dnd/drag_item.dart';
import '../dnd/staging_drop_banner.dart';
import '../viewer/file_type.dart';
import '../viewer/remote_edit_service.dart';
import 'blame_sheet.dart';
import 'commit_composer.dart';
import 'commit_composer_controller.dart';
import 'commit_dialog.dart';
import 'conflict_view.dart';
import 'diff_popout_window.dart';
import 'diff_view_controls.dart';
import 'file_view.dart';
import 'hunk_diff_view.dart';
import 'multi_file_review.dart';
import 'output_view.dart';
import 'repo_change_filter.dart';
import 'repo_change_model.dart';
import 'repo_change_navigator.dart';
import 'repo_file_selection.dart';
import 'repo_review_state.dart';
import 'repository_clean_state.dart';

/// How to proceed when a plain push would be rejected because the branch is
/// behind its upstream.
enum _PushChoice { pullThenPush, pushAnyway, cancel }

/// Which status section a selection belongs to. A selection never spans
/// sections (see [_RepoStatusViewState._handleRowTap]) — mixing, say, one
/// staged and one unstaged file makes "Stage"/"Discard" ambiguous — so this
/// single value describes every currently-selected path at once.
typedef _SectionKind = RepoChangeSection;
typedef _StatusRow = RepoChangeRow;
typedef _HeaderRow = RepoChangeHeaderRow;
typedef _FileRow = RepoChangeFileRow;

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

class _RepoStatusViewState extends ConsumerState<RepoStatusView>
    with BusyActionState {
  // Shared with the docked FileView so a tree click and a list click
  // highlight the same path.
  RepoChangeSelection get _selection =>
      ref.read(repoFileSelectionProvider(repoPath));
  RepoFileSelection get _selectionNotifier =>
      ref.read(repoFileSelectionProvider(repoPath).notifier);
  final _changeFilterController = TextEditingController();
  RepoChangeFilter _changeFilter = const RepoChangeFilter();
  bool _composerExpanded = false;
  final _reviewController = RepoReviewController();
  bool _reviewOpen = false;

  _SectionKind? get _selectionKind => _selection.section;
  set _selectionKind(_SectionKind? value) {
    _selectionNotifier.set(
      _selection.copyWith(section: value, clearSection: value == null),
    );
  }

  // Paths currently selected within _selectionKind's section. A lone path is
  // the common case and drives the diff/conflict panel; 2+ show the
  // multi-select summary panel instead.
  Set<String> get _selectedPaths => _selection.paths;
  set _selectedPaths(Set<String> value) {
    _selectionNotifier.set(_selection.copyWith(paths: Set.unmodifiable(value)));
  }

  // Anchor for shift-click range selection: the fixed end a range extends
  // from, so repeated shift-clicks extend/contract from the same point
  // rather than the last-clicked row.
  String? get _selectionAnchor => _selection.anchor;
  set _selectionAnchor(String? value) {
    _selectionNotifier.set(
      _selection.copyWith(anchor: value, clearAnchor: value == null),
    );
  }

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

  /// Whether the three diff toggles above have been seeded from the persisted
  /// workspace record yet. They were pure session state, so `diffLayout`,
  /// `ignoreWhitespace` and `diffContextLines` round-tripped to disk and were
  /// never read — the user's diff mode silently reset on every remount.
  bool _diffPrefsHydrated = false;

  /// Seeds the diff toggles from [prefs] exactly once per mount.
  Future<SSHCommandResult> _streamGitOp(
    OutputLogNotifier log,
    String label,
    Future<SSHCommandResult> Function(
      CommandOutputCallback onOutput,
      OperationId operationId,
    )
    run,
  ) async {
    // ONE id for the transcript and the operation, so the Activity Center row
    // can reveal the very lines this session writes. The executor would
    // otherwise mint its own and the two would never correlate (0023 P1).
    final operationId = OperationId.next();
    final session = log.startStream(label, operationId: operationId);
    try {
      final result = await run((chunk, {required stderr}) {
        session.append(
          chunk,
          stderr ? OutputLineKind.stderr : OutputLineKind.stdout,
        );
      }, operationId);
      session.close(exitCode: result.exitCode);
      return result;
    } catch (e) {
      if (e is GitException) {
        session.close(exitCode: e.result.exitCode);
      } else {
        session.fail(e.toString());
      }
      rethrow;
    }
  }

  void _hydrateDiffPrefs(RepositoryWorkspacePrefs prefs) {
    if (_diffPrefsHydrated) return;
    _diffPrefsHydrated = true;
    final split = prefs.diffLayout == RepositoryDiffLayout.split;
    final ignoreWs = prefs.ignoreWhitespace;
    final expand = prefs.diffContextLines > _defaultCtx;
    if (split == _diffSplit &&
        ignoreWs == _diffIgnoreWs &&
        expand == _diffExpandContext) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _diffSplit = split;
        _diffIgnoreWs = ignoreWs;
        _diffExpandContext = expand;
      });
    });
  }

  /// Persists the current diff toggles so they survive a remount.
  void _persistDiffPrefs() {
    final identity = ref.read(repositoryUiIdentityProvider(repoPath)).value;
    final prefs = ref.read(repositoryWorkspacePrefsProvider(repoPath)).value;
    if (identity == null || prefs == null) return;
    unawaited(
      saveRepositoryWorkspacePrefs(
        identity: identity,
        next: prefs.copyWith(
          diffLayout: _diffSplit
              ? RepositoryDiffLayout.split
              : RepositoryDiffLayout.unified,
          ignoreWhitespace: _diffIgnoreWs,
          diffContextLines: _diffCtx,
        ),
      ).then((_) {
        if (mounted) {
          ref.invalidate(repositoryWorkspacePrefsProvider(repoPath));
        }
      }),
    );
  }

  /// Show the inline blame gutter in the unified diff. Off by default — blame is
  /// an SSH round trip, fetched only when turned on, and only for the tracked
  /// unified diff (not split / whitespace-ignored / untracked renders).
  bool _diffBlame = false;
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

  // In-flight fetch/push count for this view. Tests stub GitService so
  // [operationActivityProvider] never sees those ops; this counter still
  // dims the sync group without holding [busy] (staging stays enabled).
  int _syncOps = 0;

  // How long after this app's own mutation a watch tick is assumed to be
  // reporting that same change (SSH round trip + the watcher's own
  // coalescing window) rather than a genuinely concurrent external one.
  static const _ownMutationSuppressWindow = Duration(seconds: 3);

  // An unscoped event-driven tick (watcher restart, overflowing burst) arrived
  // while this page was hidden. Too blunt to act on repeatedly in the
  // background — but it may have included git-state changes, so the
  // didUpdateWidget re-sync must invalidate the full mutation set, not just
  // status, when the page next becomes visible.
  bool _missedUnscopedTick = false;

  // Set when this panel invalidates the mutation families, consumed by the
  // first status landing after it — that landing is the refetch the
  // invalidation itself caused, so [_detectExternalHeadMove] must not read
  // its moved oid as a NEW external change and pay for the refresh twice.
  // A consume-once flag rather than a time window: a window would also
  // swallow a genuinely new external commit landing shortly after the
  // previous one, leaving it invisible until some unrelated refresh.
  bool _familiesRefetchPending = false;

  /// The one way this panel invalidates the shared post-mutation provider set
  /// — flags the refetch it causes so the head-move detector stands down for
  /// exactly that landing.
  /// Invalidates the families a change in [areas] can actually have staled.
  ///
  /// Defaults to the whole set, which is what an explicit mutation of our own
  /// means. A *watch tick* passes what it actually saw: staging writes only
  /// the index, and re-reading the log, refs, stashes and worktree list for
  /// that is work the change could not have caused (0025 F2).
  void _invalidateMutationFamilies([Set<GitArea>? areas]) {
    _familiesRefetchPending = true;
    for (final p in familiesFor(areas ?? const {GitArea.unknown}, repoPath)) {
      ref.invalidate(p);
    }
  }

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
  // (each selection tap, the busy toggle wrapping every git op, each diff
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
    _changeFilterController.dispose();
    _reviewController.dispose();
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
      // Same rule as a click (_handleRowTap): a popped-out diff follows the
      // selection rather than closing — popping out relocates WHERE the diff
      // shows, not which. Arrow-keying used to close it, clicking didn't.
      // It only drops when the selection lands where the popout can't follow
      // (a conflict row, which it can't render).
      if (kind == _SectionKind.conflict) _popout = false;
    });
    ensureRowVisible(_rowKeyFor(row.file.path, kind));
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || busy) {
      return KeyEventResult.ignored;
    }
    // Keys typed into a text field belong to the field, not the list — the
    // same gate PanelShortcuts applies to the ⌘-bindings (Esc in a field
    // must not clear the list selection).
    if (PanelShortcuts.textInteractionHasFocus()) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveFileSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveFileSelection(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Canonical deselect — see dnd/deselect.dart for the Esc layering
        // (overlay closes first, then a live drag cancels, then this).
        return escDeselect(
          hasSelection: _selectedPaths.isNotEmpty,
          clear: _clearSelection,
        );
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
      _changeFilterController.clear();
      _changeFilter = const RepoChangeFilter();
      _reviewOpen = false;
      _reviewController.clear();
    }
    // The watch listener skips refetching status while this page is hidden (see
    // build). Re-sync once when it becomes visible again so nothing missed while
    // away is left stale — cheaper than the per-tick background fetches the gate
    // avoids, and it makes the gate safe in both event-driven and polling modes.
    // A missed *unscoped* tick widens the re-sync to the full mutation set: it
    // may have included git-state changes no status refetch can reveal.
    // Deferred past this frame: invalidating synchronously in didUpdateWidget
    // (which runs during build) would mark the provider scope dirty mid-build.
    if (!oldWidget.isActive && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_missedUnscopedTick) {
          _missedUnscopedTick = false;
          _invalidateMutationFamilies();
        } else {
          ref.invalidate(statusProvider(repoPath));
        }
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
    // The one definition of "this repo changed" (see [repoMutationFamilies]) —
    // not a list spelled out here. Spelling it out here is exactly what broke:
    // this named `logProvider`, and when History moved to the paged, searchable
    // `logSearchProvider`, nothing updated this site. So a commit refreshed the
    // refs but left History on the pre-commit walk — and the branch/HEAD chip,
    // now pointing at a commit that was not in the list, had no row to land on
    // and vanished entirely. A set that every mutation site must remember to
    // copy will drift; one that they all read cannot.
    //
    // sequencerStateProvider follows statusProvider, so it refreshes with it —
    // no separate invalidation needed.
    _invalidateMutationFamilies();
    // The open file's worktree-backed caches — its diff at every key, its
    // conflict content, its blame — go stale through the edit stamp rather than
    // a direct `ref.invalidate` of the one key this panel happens to be
    // rendering. Two reasons, both load-bearing:
    //
    //  * An invalidate is immediate, and a diff whose FIRST read is still in
    //    flight has no value for Riverpod to carry through it — so the read is
    //    discarded and the pane restarts from a bare spinner. Since this runs
    //    after every mutation (and on the toolbar's Refresh button), a mutation
    //    landing while a slow diff was still loading killed that load and began
    //    it again; keep that up — stage hunk after hunk, or just hold Refresh —
    //    and the pane never gets to show anything. Worse, Riverpod dropping the
    //    future does not cancel the `git diff` behind it: it runs to completion
    //    unheard, still holding one of the six read slots in
    //    CommandLaneScheduler, so the reads that were meant to replace it queue
    //    behind the ones they orphaned. The stamp instead routes through
    //    _dependOnWorktreeState, which holds a stale-mark arriving mid-fetch
    //    until that fetch lands and then refetches exactly once — forward
    //    progress at any rate of change.
    //
    //  * A stamp is per (repo, path), so it reaches EVERY cached view of the
    //    file — staged and unstaged, `-w` and not, every context width, and the
    //    pop-out window's own key. The old invalidate named a single key built
    //    from this panel's own toggles, so a popped-out diff (which carries its
    //    own ignore-whitespace toggle, and so can be showing a different key
    //    entirely) was never refreshed by any mutation at all.
    //
    // Only the selected paths, not the whole repo: everything else a mutation
    // touches moves that file's status record — or HEAD, which is in the record
    // too (see _fileStateOf) — and _dependOnWorktreeState already watches those.
    // The one thing a record cannot show is a content change that leaves the
    // record identical: discard one hunk of a modified file and it is still
    // exactly `.M`. That file is the selected one, and this is what covers it.
    //
    // Same channel the filesystem watcher uses for external edits (see the
    // repoWatchProvider listener), which is the point — one way for a file's
    // content to be declared stale, whoever changed it.
    if (_selectedPaths.isNotEmpty) {
      ref
          .read(worktreeEditsProvider.notifier)
          .noteFiles(repoPath, _selectedPaths);
    }
  }

  /// HEAD moved between two landed statuses without this app mutating
  /// anything — an external commit, checkout or reset. In event-driven mode
  /// the watcher's git-state tick already catches these; this is what catches
  /// them in **polling** mode, where a tick is a blind heartbeat that can only
  /// refetch status: without it, an external commit updated the branch chip
  /// (status carries the new oid) while History, the refs and the reflog sat
  /// on the pre-commit state until ⌘R. Same answer as every other "the repo
  /// changed" signal: the shared mutation set.
  ///
  /// Two suppressions keep it from double-paying:
  ///  * a recent own mutation — its [refreshAfterMutation] already refreshed
  ///    everything (possibly from another surface: the commit dialog, the
  ///    file-tree pane, a pop-out window), and this status IS that refresh
  ///    landing;
  ///  * [_familiesRefetchPending], consumed at the call site — the watch
  ///    listener's git-state branch got there first, and this status is its
  ///    refetch.
  /// Terminates by construction: the refetch this triggers lands with the
  /// same oid/head, so the next comparison is equal.
  void _detectExternalHeadMove(GitStatus? previous, GitStatus next) {
    if (previous == null) return;
    if (previous.branch.oid == next.branch.oid &&
        previous.branch.head == next.branch.head) {
      return;
    }
    if (ref
        .read(ownMutationTrackerProvider)
        .isRecent(repoPath, DateTime.now(), _ownMutationSuppressWindow)) {
      return;
    }
    _invalidateMutationFamilies();
  }

  Future<void> _stage(String path) async {
    final git = ref.read(gitServiceProvider);
    if (await runGuarded(() => git.stage(repoPath, path))) {
      if (!mounted) return;
      // Flip the diff panel's staged flag immediately for the file just
      // staged, rather than leaving it pointed at the pre-stage diff key
      // until the next status refetch lands.
      _dropOrReselect(path, _SectionKind.staged);
    }
  }

  Future<void> _unstage(String path) async {
    final git = ref.read(gitServiceProvider);
    if (await runGuarded(() => git.unstage(repoPath, path))) {
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
      _selectionAnchor = null;
      _popout = false;
    });
  }

  /// True when [path] is selected *in* [kind]'s section. Highlighting and
  /// keyboard target checks must use this rather than a bare path set — a
  /// path can legitimately appear in more than one section (partially staged)
  /// and must not light up under the wrong header after a bulk stage moves it.
  bool _isPathSelected(String path, _SectionKind kind) =>
      _selectionKind == kind && _selectedPaths.contains(path);

  /// Keeps the selection honest against a freshly landed [status]: drop paths
  /// that left the selected section, and re-home a selection that moved as a
  /// unit (bulk stage/unstage, or an external stage of the sole selected
  /// file) so the panel follows the files instead of sitting on a stale empty
  /// key. When only *some* members left, the leavers are pruned and the rest
  /// stay — multi-select never spans sections.
  void _syncSelectionToStatus(GitStatus status) {
    final before = _selection;
    final after = before.reconcile(status);
    if (identical(after, before)) return;
    setState(() {
      _selectionNotifier.set(after);
      if (after.count != 1 || after.section == _SectionKind.conflict) {
        _popout = false;
      }
    });
  }

  /// After a bulk action moved [paths] into [newKind], re-home the selection
  /// there (or clear it if nothing remains). Mirrors [_dropOrReselect] for the
  /// multi-select case so the panel doesn't stay on a section the files just
  /// left.
  void _rehomeBulk(Iterable<String> paths, _SectionKind newKind) {
    final moved = paths.toSet();
    final keep = moved.intersection(_selectedPaths);
    if (keep.isEmpty) {
      // Action targeted paths outside the current selection (shouldn't happen
      // for the context-menu path, which selects first) — leave selection.
      return;
    }
    setState(() {
      _selectionKind = newKind;
      _selectedPaths = keep;
      _selectionAnchor = keep.contains(_selectionAnchor)
          ? _selectionAnchor
          : keep.first;
      if (keep.length != 1 || newKind == _SectionKind.conflict) {
        _popout = false;
      }
    });
  }

  /// Drops [paths] from the selection after an action that removes them from
  /// the working tree (discard, delete, gitignore, resolve).
  void _dropPathsFromSelection(Iterable<String> paths) {
    if (_selectedPaths.isEmpty) return;
    final gone = paths.toSet();
    if (!_selectedPaths.any(gone.contains)) return;
    setState(() {
      _selectedPaths = {..._selectedPaths}..removeAll(gone);
      if (_selectedPaths.isEmpty) {
        _selectionKind = null;
        _selectionAnchor = null;
        _popout = false;
      } else if (_selectionAnchor != null &&
          !_selectedPaths.contains(_selectionAnchor)) {
        _selectionAnchor = _selectedPaths.first;
      }
    });
  }

  Future<void> _stageAll() async {
    final git = ref.read(gitServiceProvider);
    await runGuarded(() => git.stageAll(repoPath));
  }

  /// The mirror of [_stageAll]. No confirmation: unstaging destroys nothing —
  /// every change stays in the working tree, and Stage All puts it back.
  Future<void> _unstageAll() async {
    final git = ref.read(gitServiceProvider);
    await runGuarded(() => git.unstageAll(repoPath));
  }

  /// Folds the currently staged changes into HEAD, keeping its message — the
  /// same confirm-then-amend flow History offers, brought to the panel where
  /// staging actually happens ("staged the fix, meant it for the last
  /// commit"). Undoable: [GitService.amendCommit] records a reset-soft entry.
  Future<void> _amend() async {
    final ok = await confirmAction(
      context,
      title: 'Amend last commit',
      message:
          'Amend HEAD with the currently staged changes? This rewrites the '
          'commit — avoid it if the commit is already pushed.',
      confirmLabel: 'Amend',
    );
    if (!ok || !mounted) return;
    final git = ref.read(gitServiceProvider);
    await runGuarded(() => git.amendCommit(repoPath));
  }

  String _stagedSignature(GitStatus status) {
    final parts = [
      for (final file in status.staged)
        '${file.path}\u001f${file.statusX}\u001f${file.statusY}',
    ]..sort();
    return parts.join('\u001e');
  }

  /// Opens whichever commit surface this repository prefers (0012).
  ///
  /// One entry point for all three routes — the Commit… bar, the staged
  /// section's primary action, and `repository.focusCommit` — so the choice is
  /// made in exactly one place and the two surfaces can never disagree.
  void _openCommitComposer() {
    final surface =
        ref
            .read(repositoryWorkspacePrefsProvider(repoPath))
            .value
            ?.commitSurface ??
        defaultCommitSurface;
    switch (surface) {
      case CommitSurface.sheet:
        unawaited(_openCommitDialog());
      case CommitSurface.dock:
        _expandCommitComposer();
    }
  }

  /// Opens the focused commit sheet (0012).
  ///
  /// Unlike [_expandCommitComposer] this consults no layout preference: a
  /// sheet is drawn over the workspace, so it cannot be hidden by a collapsed
  /// dock the way ⌘G was under three of the four presets (0008-PLAN B9).
  Future<void> _openCommitDialog() async {
    final status = ref.read(statusProvider(repoPath)).value;
    final stagedCount = status?.staged.length ?? 0;
    if (stagedCount == 0) return;
    await showMacosSheet<bool>(
      context: context,
      builder: (_) => EscapeDismissible(
        child: CommitDialog(
          repoPath: repoPath,
          stagedCount: stagedCount,
          branchLabel: status!.branch.head ?? 'Detached HEAD',
          // Push policy stays here — the guardrail, force/upstream variants,
          // follow-tags and output logging all live in `_push`.
          onPush: () =>
              _push(followTags: ref.read(appSettingsProvider).pushFollowTags),
        ),
      ),
    );
  }

  /// Opens the expanded composer, un-collapsing the task dock if needed.
  ///
  /// Setting `_composerExpanded` alone was not enough: `AdaptiveWorkspaceLayout`
  /// hides the dock entirely when `taskDockCollapsed`, and the Review,
  /// Investigate and Minimal presets all set that — so ⌘G was a silent no-op
  /// under three of the four presets.
  void _expandCommitComposer() {
    if (!_composerExpanded) setState(() => _composerExpanded = true);
    final prefs = ref.read(repositoryWorkspacePrefsProvider(repoPath)).value;
    final identity = ref.read(repositoryUiIdentityProvider(repoPath)).value;
    if (prefs != null && identity != null && prefs.taskDockCollapsed) {
      unawaited(
        saveRepositoryWorkspacePrefs(
          identity: identity,
          next: prefs.copyWith(taskDockCollapsed: false),
        ).then((_) {
          if (mounted) {
            ref.invalidate(repositoryWorkspacePrefsProvider(repoPath));
          }
        }),
      );
    }
  }

  Future<void> _acceptCommitComposer(
    CommitComposerController controller,
    bool push,
  ) async {
    final outcome = await controller.submit(
      commit: (message) => runGuarded(
        () => ref.read(gitServiceProvider).commit(repoPath, message: message),
      ),
      push: push
          ? () =>
                _push(followTags: ref.read(appSettingsProvider).pushFollowTags)
          : null,
    );
    if (!mounted || !outcome.localCommitted) return;
    if (!push) {
      ref
          .read(connectionProvider.notifier)
          .fetchInBackground(repoPath)
          .ignore();
    }
    setState(() => _composerExpanded = false);
  }

  @override
  void refreshAfterAction() => _refresh();

  /// The upstream's remote name from the status snapshot already in RAM, or
  /// null when it cannot be derived — in which case GitService falls back to
  /// its own probe. Saves a `sh -c` round trip (measured 37.6 ms locally, one
  /// SSH round trip remotely) on every push/pull that would otherwise run it.
  ///
  /// Read, not watched: this must be the state as it stands when the operation
  /// starts, and a watch tick mid-operation must not change the answer under
  /// it.
  String? _upstreamRemoteHint() {
    final snapshot = ref.read(statusProvider(repoPath)).value;
    final remotes = ref.read(remotesProvider(repoPath)).value;
    if (snapshot == null || remotes == null) return null;
    return GitService.remoteFromUpstream(snapshot.branch.upstream, remotes);
  }

  Future<void> _fetch() async {
    final git = ref.read(gitServiceProvider);
    if (mounted) setState(() => _syncOps++);
    try {
      await runLogged(
        'git fetch --all --prune',
        (log) async {
          await withOwnMutation(
            ref.read(ownMutationTrackerProvider),
            repoPath,
            () async {
              await _streamGitOp(
                log,
                'git fetch --all --prune',
                (onOutput, opId) =>
                    git.fetch(repoPath, onOutput: onOutput, operationId: opId),
              );
            },
          );
        },
        dock: true,
        holdBusy: false,
        refresh: () => refreshAfterFetch(ref, repoPath),
      );
    } finally {
      if (mounted) setState(() => _syncOps--);
    }
  }

  Future<void> _stashPush() async {
    final git = ref.read(gitServiceProvider);
    // `--include-untracked`, for the same reason guardedBranchSwitch forces
    // it: this panel counts untracked files as changes, so a user with an
    // untracked-only tree who clicks Stash would otherwise get a silent
    // "No local changes to save" no-op and believe the work was parked. The
    // Stashes panel's menu still offers the tracked-only variant explicitly.
    await runLogged(
      'git stash push',
      (log) async => log.logResult(
        'git stash push --include-untracked',
        await git.stashPush(repoPath, includeUntracked: true),
      ),
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
    String? before;
    final ok = await runLogged(label, (log) async {
      before = await git.revParse(repoPath, 'HEAD');
      // See _push: the mark must precede runLogged's refresh. A pull's fetch
      // half writes refs/remotes/** while still running, so without this the
      // watcher fires a full refresh mid-pull.
      await withOwnMutation(
        ref.read(ownMutationTrackerProvider),
        repoPath,
        () async {
          await _streamGitOp(
            log,
            label,
            (onOutput, opId) => git.pull(
              repoPath,
              mode: mode,
              onOutput: onOutput,
              operationId: opId,
            ),
          );
        },
      );
    }, dock: true);
    if (ok && mounted) {
      try {
        await _logPulled(ref.read(outputLogProvider.notifier), git, before);
      } catch (e) {
        ref
            .read(outputLogProvider.notifier)
            .logError('pulled files', e.toString());
      }
    }
  }

  Future<bool> _push({
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
        if (!mounted) return false;
        if (choice == null || choice == _PushChoice.cancel) return false;
        if (choice == _PushChoice.pullThenPush) {
          // _sync inlines pull-then-push and skips the push if the pull fails.
          await _sync(ref.read(appSettingsProvider).defaultPullMode);
          return true;
        }
      }
    }
    if (!mounted) return false;
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
      if (!ok || !mounted) return false;
    }
    final git = ref.read(gitServiceProvider);
    final label = [
      'git push',
      if (force == PushForce.withLease) '--force-with-lease',
      if (force == PushForce.force) '--force',
      if (setUpstream) '-u',
      if (followTags) '--follow-tags',
    ].join(' ');
    if (mounted) setState(() => _syncOps++);
    final hint = _upstreamRemoteHint();
    String? base;
    final bool success;
    try {
      success = await runLogged(
        label,
        (log) async {
          base = await git.revParse(repoPath, '@{upstream}');
          // Wrapped INSIDE the body, not around runLogged: `end()` (which
          // marks) must land before runLogged's finally invalidates, or the
          // watcher echo arriving moments later is not suppressed. Wrapping
          // outside would also hold the in-flight mark for as long as an error
          // dialog stays open, suppressing genuinely external changes.
          await withOwnMutation(
            ref.read(ownMutationTrackerProvider),
            repoPath,
            () async {
              await _streamGitOp(
                log,
                label,
                (onOutput, opId) => git.push(
                  repoPath,
                  force: force,
                  setUpstream: setUpstream,
                  followTags: followTags,
                  onOutput: onOutput,
                  operationId: opId,
                  upstreamRemote: hint,
                ),
              );
            },
          );
        },
        dock: true,
        holdBusy: false,
        // A push moves neither HEAD, the index, nor the worktree — so History,
        // stashes, reflog, snapshots and worktrees cannot have changed. The
        // full mutation set re-walked all of them after every push; this is the
        // set `repoFetchFamilies` documents itself as being for ("a fetch OR
        // push"), and the half of 0020 H5 that only ever landed for fetch.
        refresh: () => refreshAfterFetch(ref, repoPath),
      );
    } finally {
      if (mounted) setState(() => _syncOps--);
    }
    if (success && mounted) {
      try {
        await _logPushed(ref.read(outputLogProvider.notifier), git, base);
      } catch (e) {
        ref
            .read(outputLogProvider.notifier)
            .logError('pushed files', e.toString());
      }
    }
    // A --follow-tags push may have just put local tags on the remote — the
    // cached remote-tag listing is stale.
    if (followTags && mounted) refreshRemoteTags(ref, repoPath);
    return success;
  }

  Future<void> _sync([PullMode mode = PullMode.ffOnly]) async {
    final git = ref.read(gitServiceProvider);
    final pullLabel = _pullLabel(mode);
    // Inlined pull-then-push (rather than git.sync) so each phase can report the
    // files it moved: the push base is @{upstream} *after* the pull advanced it.
    String? before;
    String? pushBase;
    final ok = await runLogged('git sync', (log) async {
      before = await git.revParse(repoPath, 'HEAD');
      // One mark spanning both phases: a sync's own writes (refs from the
      // fetch, then the push's tracking refs) must not each trigger a refresh
      // while the other half is still running.
      await withOwnMutation(
        ref.read(ownMutationTrackerProvider),
        repoPath,
        () async {
          await _streamGitOp(
            log,
            pullLabel,
            (onOutput, opId) => git.pull(
              repoPath,
              mode: mode,
              onOutput: onOutput,
              operationId: opId,
            ),
          );
          pushBase = await git.revParse(repoPath, '@{upstream}');
          await _streamGitOp(
            log,
            'git push',
            (onOutput, opId) =>
                git.push(repoPath, onOutput: onOutput, operationId: opId),
          );
        },
      );
    }, dock: true);
    if (ok && mounted) {
      final out = ref.read(outputLogProvider.notifier);
      try {
        // One process for what used to be four round trips: two
        // `rev-parse HEAD` — a literal duplicate, since _logPulled and
        // _logPushed each asked and a push cannot move HEAD — and two
        // `diff --name-status` (0023 A1).
        final report = await git.syncFileReport(
          repoPath,
          pullBase: before,
          pushBase: pushBase,
        );
        final head = report.head;
        if (before != null && head != null && before != head) {
          out.logFiles('Pulled', report.pulled);
        }
        if (pushBase != null && head != null && pushBase != head) {
          out.logFiles('Pushed', report.pushed);
        }
      } catch (e) {
        out.logError('sync file report', e.toString());
      }
    }
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
      destructive: true,
    );
    if (ok) {
      await runGuarded(
        () => ref.read(gitServiceProvider).discard(repoPath, path),
      );
    }
  }

  /// Deletes a single untracked file from the working tree. Mirrors [_discard]
  /// (same confirmation pattern, same [runGuarded] gate so it can't
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
      destructive: true,
    );
    if (ok) {
      await runGuarded(
        () => ref.read(gitServiceProvider).removeUntrackedFile(repoPath, path),
      );
    }
  }

  Future<void> _resolve(String path, {required bool useOurs}) async {
    final git = ref.read(gitServiceProvider);
    if (await runGuarded(
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
      destructive: true,
    );
    if (ok) {
      await runGuarded(
        () => ref.read(gitServiceProvider).discardStaged(repoPath, path),
      );
    }
  }

  Future<void> _addToGitignore(String path) async {
    await runGuarded(
      () => ref.read(gitServiceProvider).addToGitignore(repoPath, path),
    );
  }

  // ---- Bulk (multi-select) file actions -------------------------------
  // Each calls the corresponding batch GitService method (one git invocation
  // covering the whole selection) inside one runGuarded — same
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
    if (await runGuarded(
      () => ref.read(gitServiceProvider).stageMany(repoPath, paths),
    )) {
      if (!mounted) return;
      // Follow the files into Staged — same bookkeeping as a single-file
      // stage, for the multi-select case.
      _rehomeBulk(paths, _SectionKind.staged);
    }
  }

  Future<void> _unstageMany(List<String> paths) async {
    if (await runGuarded(
      () => ref.read(gitServiceProvider).unstageMany(repoPath, paths),
    )) {
      if (!mounted) return;
      _rehomeBulk(paths, _SectionKind.unstaged);
    }
  }

  Future<void> _discardMany(List<String> paths) async {
    final ok = await confirmAction(
      context,
      title: 'Discard changes',
      message:
          'Discard working-tree changes to ${_fileListSummary(paths)}? '
          'The content is snapshotted first — press ⌘Z to undo.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!ok) return;
    if (await runGuarded(
      () => ref.read(gitServiceProvider).discardMany(repoPath, paths),
    )) {
      if (!mounted) return;
      _dropPathsFromSelection(paths);
    }
  }

  Future<void> _discardUntrackedMany(List<String> paths) async {
    final ok = await confirmAction(
      context,
      title: 'Delete untracked files',
      message:
          'Delete ${_fileListSummary(paths)}? Their content is snapshotted '
          'first — press ⌘Z to undo.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    if (await runGuarded(
      () => ref
          .read(gitServiceProvider)
          .removeUntrackedFilesMany(repoPath, paths),
    )) {
      if (!mounted) return;
      _dropPathsFromSelection(paths);
    }
  }

  Future<void> _discardStagedMany(List<String> paths) async {
    final ok = await confirmAction(
      context,
      title: 'Discard staged changes',
      message:
          'Discard staged changes to ${_fileListSummary(paths)}? The '
          'content is snapshotted first — press ⌘Z to undo.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!ok) return;
    if (await runGuarded(
      () => ref.read(gitServiceProvider).discardStagedMany(repoPath, paths),
    )) {
      if (!mounted) return;
      _dropPathsFromSelection(paths);
    }
  }

  Future<void> _addToGitignoreMany(List<String> paths) async {
    if (await runGuarded(
      () => ref.read(gitServiceProvider).addToGitignoreMany(repoPath, paths),
    )) {
      if (!mounted) return;
      _dropPathsFromSelection(paths);
    }
  }

  Future<void> _resolveMany(List<String> paths, {required bool useOurs}) async {
    if (await runGuarded(
      () => ref
          .read(gitServiceProvider)
          .resolveConflictMany(repoPath, paths, useOurs: useOurs),
    )) {
      if (!mounted) return;
      _dropPathsFromSelection(paths);
    }
  }

  static String _pendingVerb(PendingOp op) => switch (op) {
    PendingOp.merge => 'Merge',
    PendingOp.cherryPick => 'Cherry-pick',
    PendingOp.revert => 'Revert',
    PendingOp.rebase => 'Rebase',
    PendingOp.am => 'Patch application',
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
    if (await runGuarded(
      () => switch (op) {
        PendingOp.merge => git.mergeAbort(repoPath),
        PendingOp.cherryPick => git.cherryPickAbort(repoPath),
        PendingOp.revert => git.revertAbort(repoPath),
        PendingOp.rebase => git.rebaseAbort(repoPath),
        PendingOp.am => git.amAbort(repoPath),
        PendingOp.none => Future<void>.value(),
      },
    )) {
      if (!mounted) return;
      _clearSelection();
    }
  }

  /// The matching `--continue` for whichever operation is paused — the
  /// prepared message (MERGE_MSG / the sequencer's) commits as-is, so a
  /// hand-resolved conflict needs no composer round-trip (0009 M14).
  Future<void> _continuePending(PendingOp op) async {
    final git = ref.read(gitServiceProvider);
    final (label, run) = switch (op) {
      PendingOp.rebase => ('git rebase --continue', git.rebaseContinue),
      PendingOp.merge => ('git merge --continue', git.mergeContinue),
      PendingOp.cherryPick => (
        'git cherry-pick --continue',
        git.cherryPickContinue,
      ),
      PendingOp.revert => ('git revert --continue', git.revertContinue),
      PendingOp.am => ('git am --continue', git.amContinue),
      // The banner only renders for a real pending op.
      PendingOp.none => ('', git.rebaseContinue),
    };
    if (op == PendingOp.none) return;
    final ok = await runLogged(label, (log) async {
      log.logResult(label, await run(repoPath));
    });
    // Same reasoning as _abortPending: only clear on success.
    if (ok && mounted) _clearSelection();
  }

  /// Banner shown while a merge/cherry-pick/revert/rebase is mid-flight (usually
  /// after a conflict), offering to continue (rebase) and/or abort.
  Widget _pendingBanner(BuildContext context, PendingOp op) {
    final typography = MacosTheme.of(context).typography;
    final verb = _pendingVerb(op);
    final hint =
        '$verb in progress — resolve conflicts, then continue, or abort.';
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
          InlineActionButton(
            label: 'Continue',
            icon: CupertinoIcons.play,
            onPressed: () => _continuePending(op),
          ),
          const SizedBox(width: 8),
          InlineActionButton(
            label: 'Abort $verb',
            // Aborting throws the in-progress operation (and any conflict
            // resolution done so far) away — it gets the red.
            icon: CupertinoIcons.arrow_uturn_left,
            tone: InlineActionTone.destructive,
            onPressed: () => _abortPending(op),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The selection now lives in a provider shared with the file trees, so a
    // tree-driven change has to rebuild this view. `setState` used to cover
    // that for free when the selection was local state.
    ref.watch(repoFileSelectionProvider(repoPath));

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
      // An event-driven tick is a real filesystem change. Record it against the
      // paths that actually moved: porcelain status can't see a content-only
      // edit to an already-modified file (identical records, different bytes),
      // so without this signal the diff/blame/conflict caches would go on
      // serving pre-edit content — and with it recorded repo-wide, as it once
      // was, every one of them for every file would be thrown away on any event
      // at all. The tick has already been filtered of paths git ignores (see
      // repoWatchProvider), so what arrives here is only ever real.
      //
      // Recorded even while the page is hidden (it's a local counter, no round
      // trip) so the didUpdateWidget re-sync on return sees it.
      if (event.mode == WatchMode.eventDriven) {
        final edits = ref.read(worktreeEditsProvider.notifier);
        // Unscoped (a poll, a watcher restart, a burst too large to enumerate)
        // means "anything may have changed" — not "nothing did". So does a move
        // in git's own state, which belongs to no single file (see
        // [RepoWatchEvent.touchesGitState]).
        if (event.isScoped && !event.touchesGitState) {
          edits.noteFiles(repoPath, event.paths);
        } else {
          edits.noteRepo(repoPath);
        }
      }
      // A tick that moved git's own state — a commit, checkout, branch, rebase
      // or fetch run in a terminal or another tool — moved more than the file
      // list: HEAD, the refs, the stashes and the reflog can all be somewhere
      // else now. Refreshing status alone left History showing a walk that
      // predates the commit you just made outside the app, with the branch chip
      // still on the old tip, until you hit ⌘R. It is the same question a
      // mutation of our own asks, so it gets the same answer.
      //
      // Deliberately NOT behind the visibility gate below: the providers this
      // refreshes are shared across panels, and the other panels stay mounted
      // (IndexedStack) and watching them while this page is hidden — a commit
      // made in a terminal while the user sits on History must appear in
      // History now, not after they detour through the Repository tab. Cheap
      // by nature: it takes a real git operation, not a build, to trip this.
      //
      // Deliberately gated on [RepoWatchEvent.touchesGitState] (an event-driven
      // tick naming a path under `.git`), not on every tick: a polling tick is a
      // blind heartbeat that fires every few seconds whether or not anything
      // happened, and re-walking the whole log on each of those would be a
      // round trip per poll for nothing. (Polling-mode external commits are
      // still caught — by [_detectExternalHeadMove], off the status refetch.)
      if (event.mode == WatchMode.eventDriven && event.touchesGitState) {
        _invalidateMutationFamilies(event.touchedAreas);
        return;
      }
      // While this page is hidden (another tab is up) don't fire a `git status`
      // round-trip on every tick — in polling mode that's a fetch every few
      // seconds against a repo the user isn't looking at. Keep the subscription
      // (so the watcher stays alive) but skip the refetch; didUpdateWidget
      // re-syncs once when the page becomes visible again. An unscoped
      // event-driven tick (watcher restart, overflowing burst) is remembered so
      // that re-sync covers the git state it may have hidden.
      if (!widget.isActive) {
        if (event.mode == WatchMode.eventDriven && !event.isScoped) {
          _missedUnscopedTick = true;
        }
        return;
      }
      // An unscoped event-driven tick can't say what moved — git state
      // included — so it gets the full-refresh answer too.
      if (event.mode == WatchMode.eventDriven && !event.isScoped) {
        _invalidateMutationFamilies();
        return;
      }
      // Otherwise only the working tree moved. Refresh status; the structure
      // tree, status overlay, and sequencer state all follow from it (the tree
      // only re-fetches when its shape changes — see repoStructureProvider).
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
      if (status == null) return;
      // Consume-once: this landing is (at most) the refetch our own families
      // invalidation triggered — the world was refreshed alongside it, so a
      // moved oid here is old news. Later landings detect normally. Gated on
      // a genuine data landing: an invalidation first emits a loading state
      // still carrying the OLD value, and consuming the flag on that
      // transition would let the actual landing double-pay after all.
      if (!next.isLoading) {
        final skipDetect = _familiesRefetchPending;
        _familiesRefetchPending = false;
        if (!skipDetect) _detectExternalHeadMove(previous?.value, status);
      }
      // Section-aware prune / single-file re-home. Path-only presence was not
      // enough: a bulk or external stage leaves the path in status.files but
      // under a different section, and the panel kept requesting the old
      // (now empty) diff key.
      _syncSelectionToStatus(status);
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
    final remotes = ref.watch(remotesProvider(repoPath)).value;
    final identity = ref.watch(repositoryUiIdentityProvider(repoPath)).value;
    final workspacePreferences =
        ref.watch(repositoryWorkspacePrefsProvider(repoPath)).value ??
        const RepositoryWorkspacePrefs();
    _hydrateDiffPrefs(workspacePreferences);
    final typography = MacosTheme.of(context).typography;
    final sessionWarning = ref.watch(
      connectionProvider.select((c) => c.warning),
    );
    final outputVisible = ref.watch(outputLogProvider.select((s) => s.visible));
    final fileVisible = ref.watch(fileViewVisibleProvider);

    final status = statusAsync.value;
    final connection = ref.watch(connectionProvider);
    // 0009 H3: apply a restored / palette-revealed file location once status
    // can classify its section (conflict pane for unmerged, like the tree).
    final pendingLocation = widget.isActive
        ? pendingWorkspaceLocation(ref, 0)
        : null;
    if (pendingLocation != null && status != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final location = takeWorkspaceLocation(ref, 0);
        if (location == null) return;
        final s = ref
            .read(repoStatusOverlayProvider(repoPath))
            .statusFor(location.identity);
        final untracked = s?.isUntracked ?? false;
        final conflict = s?.isUnmerged ?? false;
        _openFileFromTree(
          location.identity,
          staged:
              !conflict &&
              !untracked &&
              (s?.isStaged ?? false) &&
              !(s?.isUnstaged ?? false),
          untracked: untracked,
          conflict: conflict,
        );
      });
    }
    final composerController = ref.watch(
      commitComposerControllerProvider(
        CommitComposerKey(repoPath, connection.sessionEpoch),
      ),
    );
    if (status != null) {
      final stagedSignature = _stagedSignature(status);
      if (composerController.stagedCount != status.staged.length ||
          composerController.stagedSignature != stagedSignature) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          composerController.updateStaged(
            count: status.staged.length,
            signature: stagedSignature,
          );
        });
      }
    }
    final identityKey = repositoryContextIdentityKey(
      backend: connection.backend.name,
      connectionId: connection.connectionId,
      repositoryPath: repoPath,
    );
    final supplementKey = connection.sessionEpoch > 0
        ? RepositoryContextSupplementKey(
            repositoryIdentity: identityKey,
            sessionEpoch: connection.sessionEpoch,
          )
        : null;
    final supplement = supplementKey == null
        ? null
        : ref.watch(
            repositoryContextSupplementCacheProvider.select(
              (cache) => cache[supplementKey],
            ),
          );
    final branch = status?.branch;
    final commitPolicyAdvisory = supplement?.commitPolicyBranch == branch?.head
        ? supplement?.commitPolicyLabel
        : null;
    final pathSegments = repoPath.split('/').where((part) => part.isNotEmpty);
    final snapshot = RepositoryContextSnapshot(
      repositoryPath: repoPath,
      repositoryName: pathSegments.isEmpty ? repoPath : pathSegments.last,
      connectionLabel: connection.connectionLabel,
      hostLabel: connection.isLocal ? 'On this Mac' : connection.host,
      branchLabel: branch == null
          ? 'Loading branch…'
          : branch.isDetached
          ? 'Detached HEAD'
          : branch.head ?? 'Unborn branch',
      upstreamLabel: branch?.upstream,
      ahead: branch?.ahead ?? 0,
      behind: branch?.behind ?? 0,
      changedCount: status?.files.length,
      conflictCount: status?.conflicted.length,
      hasPendingOperation: pending != null && pending != PendingOp.none,
      hasUpstream: branch?.hasUpstream ?? false,
      hasConfiguredRemote: remotes?.isNotEmpty ?? false,
      connected: connection.isConnected,
      busy: busy,
      incomplete: status == null || remotes == null || pending == null,
      refCount: refs?.length ?? 0,
      // Ambient repository state that used to live in the second toolbar band:
      // it describes the repository, so it now sits with the repository's
      // identity instead of in a strip of its own.
      watchHealth: switch (watchMode) {
        WatchMode.eventDriven => RepositoryWatchHealth.live,
        WatchMode.polling => RepositoryWatchHealth.degraded,
        WatchMode.stopped || null => RepositoryWatchHealth.stopped,
      },
      watchHint: switch (watchMode) {
        WatchMode.eventDriven => 'Live file watcher',
        WatchMode.polling => 'Polling for changes (watcher unavailable)',
        WatchMode.stopped || null => 'Watcher stopped',
      },
      // Null (still loading) counts as "has a remote" so the caption does not
      // flash on before the first fetch resolves. A wired-but-empty repo says
      // so rather than implying its remote setup failed.
      notice: remotes != null && remotes.isEmpty
          ? 'No remote detected'
          : refs != null && refs.isEmpty
          ? 'No branches yet — repository is empty'
          : null,
      noticeTone: remotes != null && remotes.isEmpty
          ? RepositoryNoticeTone.warning
          : RepositoryNoticeTone.info,
      supplement: supplement,
    );
    final primaryAction = resolvePrimaryRepositoryAction(snapshot);
    // The four sync verbs are always on screen with fixed meanings; the ladder
    // above only decides which one is emphasized. Unavailability is stated per
    // verb, with the reason, so a dimmed button explains itself.
    final activitySync = ref
        .watch(operationActivityProvider)
        .any(
          (record) =>
              !record.isTerminal &&
              record.descriptor.repositoryPath == repoPath &&
              record.descriptor.kind == OperationKind.synchronization,
        );
    final syncGroup = RepositorySyncGroup(
      onInvoke: _invokeSyncCommand,
      unavailable: _syncUnavailability(
        busy: busy,
        syncRunning: _syncOps > 0 || activitySync,
        connected: connection.isConnected,
        hasRemote:
            (remotes?.isNotEmpty ?? false) || (branch?.hasUpstream ?? false),
        hasUpstream: branch?.hasUpstream ?? false,
      ),
    );
    final selected = _selected;
    // The multi-select operands for toggleStage/discard (0009 M12) — one
    // section at a time, exactly like the context menu's bulk actions.
    final multiPaths = _selectedPaths.length > 1
        ? _selectedPaths.toList()
        : null;
    final multiKind = multiPaths == null ? null : _selectionKind;
    final keymap = ref.watch(keymapProvider);
    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'repository.fetch': _fetch,
      'repository.push': () =>
          _push(followTags: ref.read(appSettingsProvider).pushFollowTags),
      'repository.pull': () =>
          _pull(ref.read(appSettingsProvider).defaultPullMode),
      'repository.stash': _stashPush,
      'repository.sync': _sync,
      'repository.forcePush': () => _push(force: PushForce.withLease),
      // The variants that used to live only in the toolbar's overflow menu.
      // Each is the same call the menu made, so nothing forks.
      'repository.pullRebase': () => _pull(PullMode.rebase),
      'repository.pullMerge': () => _pull(PullMode.merge),
      'repository.pushSetUpstream': () => _push(setUpstream: true),
      'repository.pushTags': () => _push(followTags: true),
      'repository.forcePushHard': () => _push(force: PushForce.force),
      'repository.amend': _amend,
      'repository.abortPending': pending == null || pending == PendingOp.none
          ? null
          : () => _abortPending(pending),
      'repository.stageAll':
          status != null &&
              (status.unstaged.isNotEmpty || status.untracked.isNotEmpty)
          ? _stageAll
          : null,
      'repository.unstageAll': status != null && status.staged.isNotEmpty
          ? _unstageAll
          : null,
      // Diff-view toggles: only meaningful while a file's diff is showing,
      // so they fall through (null) when nothing is selected.
      'repository.toggleSplitDiff': selected == null
          ? null
          : () {
              setState(() => _diffSplit = !_diffSplit);
              _persistDiffPrefs();
            },
      'repository.toggleIgnoreWhitespace': selected == null
          ? null
          : () {
              setState(() => _diffIgnoreWs = !_diffIgnoreWs);
              _persistDiffPrefs();
            },
      'repository.toggleExpandContext': selected == null
          ? null
          : () {
              setState(() => _diffExpandContext = !_diffExpandContext);
              _persistDiffPrefs();
            },
      // Multi-selections route to the same bulk helpers the context menu
      // uses (0009 M12); conflicts stay excluded — resolving is an explicit
      // menu/toolbar act, never a stray Space.
      'repository.toggleStage': selected != null
          ? () => selected.staged
                ? _unstage(selected.path)
                : _stage(selected.path)
          : multiKind == _SectionKind.staged
          ? () => _unstageMany(multiPaths!)
          : multiKind == _SectionKind.unstaged ||
                multiKind == _SectionKind.untracked
          ? () => _stageMany(multiPaths!)
          : null,
      // Discard is only offered for unstaged rows elsewhere in this view
      // (the "discardable" rows: unstaged tracked changes and untracked
      // files) — matched here so the shortcut can't silently discard a
      // staged selection. Untracked routes to the delete-file action
      // instead of `git restore`, same split as the file-list row below.
      'repository.discard': selected != null && !selected.staged
          ? () => selected.untracked
                ? _discardUntracked(selected.path)
                : _discard(selected.path)
          : multiKind == _SectionKind.unstaged
          ? () => _discardMany(multiPaths!)
          : multiKind == _SectionKind.untracked
          ? () => _discardUntrackedMany(multiPaths!)
          : null,
      'repository.focusCommit': status != null && status.staged.isNotEmpty
          ? _openCommitComposer
          : null,
    };
    final live = widget.isActive && !busy;
    final ValueChanged<RepositoryWorkspacePrefs>? saveWorkspacePreferences =
        identity == null
        ? null
        : (next) {
            saveRepositoryWorkspacePrefs(identity: identity, next: next).then((
              _,
            ) {
              if (mounted) {
                ref.invalidate(repositoryWorkspacePrefsProvider(repoPath));
              }
            }).ignore();
          };

    return PanelShortcuts(
      bindings: live
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: live ? handlers : const {},
      child: LayoutBuilder(
        builder: (context, constraints) {
          final statusArea = Expanded(
            child: statusAsync.when(
              loading: () => const Center(child: ProgressCircle()),
              error: (err, _) {
                // Connect-time `gh`/`glab auth login` races the first git
                // reads; a "not logged in" failure is still in-progress
                // login, not a broken working tree.
                final pending = ref.watch(
                  connectionProvider.select((c) => c.forgeAuthPending),
                );
                if (isTransportNotReady(err) ||
                    (pending && looksLikeAuthFailure(err))) {
                  return const Center(child: ProgressCircle());
                }
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      displayError(err),
                      style: typography.body.copyWith(
                        color: MacosColors.systemRedColor,
                      ),
                    ),
                  ),
                );
              },
              data: (status) => _body(
                context,
                status,
                preferences: workspacePreferences,
                onPreferencesChanged: saveWorkspacePreferences,
                supplement: supplement,
              ),
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
              if (sessionWarning != null)
                _warningBanner(context, sessionWarning),
              if (pending != null && pending != PendingOp.none)
                _pendingBanner(context, pending),
              statusArea,
              if (status != null && !status.isClean)
                _commitBar(
                  context,
                  status,
                  composerController,
                  policyAdvisory: commitPolicyAdvisory,
                ),
              if (outputVisible) OutputView(maxHeight: constraints.maxHeight),
            ],
          );
          final canvas = LayoutBuilder(
            builder: (context, canvasConstraints) => Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: centerColumn),
                    if ((fileVisible || workspacePreferences.filesPinned) &&
                        canvasConstraints.maxWidth >= 1200)
                      FileView(
                        maxWidth: canvasConstraints.maxWidth,
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
                    expandedContext: _diffExpandContext,
                    onToggleContext: () {
                      setState(() => _diffExpandContext = !_diffExpandContext);
                      _persistDiffPrefs();
                    },
                    bounds: Size(
                      canvasConstraints.maxWidth,
                      canvasConstraints.maxHeight,
                    ),
                    onHunkAction: _applyHunk,
                    onSelectionAction: _applySelection,
                    onClose: () => setState(() => _popout = false),
                  ),
              ],
            ),
          );
          return RepositoryWorkspaceScaffold(
            repositoryContext: RepositoryContextBar(
              snapshot: snapshot,
              primaryAction: primaryAction,
              syncGroup: syncGroup,
              onStash: busy ? null : _stashPush,
              onRefresh: _refresh,
              showLinkStatus: !connection.isLocal,
              onToggleSidebar: () =>
                  MacosWindowScope.maybeOf(context)?.toggleSidebar(),
              onRevealOutput: (id) {
                ref.read(outputLogProvider.notifier).setVisible(true);
                ref.read(outputRevealProvider.notifier).request(id);
              },
              onPrimaryAction: (kind) => _invokePrimaryRepositoryAction(
                kind,
                status: status,
                pending: pending,
              ),
            ),
            canvas: canvas,
            taskDock:
                _composerExpanded && status != null && status.staged.isNotEmpty
                ? CommitComposer(
                    controller: composerController,
                    presentation: CommitComposerPresentation.expanded,
                    branchLabel: status.branch.head ?? 'Detached HEAD',
                    policyAdvisory: commitPolicyAdvisory,
                    onAccept: (push) =>
                        _acceptCommitComposer(composerController, push),
                    onCollapse: () => setState(() => _composerExpanded = false),
                    focused: true,
                  )
                : null,
            taskDockFocused: _composerExpanded,
            preferences: workspacePreferences,
            onPreferencesChanged: saveWorkspacePreferences,
            workspaceOptionsEnabled: true,
          );
        },
      ),
    );
  }

  /// Why each sync verb cannot run, when it cannot. Absent means available.
  ///
  /// Stated once here rather than at each button: the reasons are properties
  /// of the repository (no connection, no remote, no upstream, an operation
  /// already running), not of the widgets.
  Map<RepositorySyncCommand, String> _syncUnavailability({
    required bool busy,
    required bool syncRunning,
    required bool connected,
    required bool hasRemote,
    required bool hasUpstream,
  }) {
    final blanket = !connected
        ? 'Repository is disconnected'
        : busy
        ? 'Another repository operation is running'
        : !hasRemote
        ? 'No remote is configured'
        : syncRunning
        ? 'A fetch or push is already running'
        : null;
    if (blanket != null) {
      return {
        for (final command in RepositorySyncCommand.values) command: blanket,
      };
    }
    if (hasUpstream) return const {};
    // A branch with no upstream can still be pushed — that is what
    // `--set-upstream` is for — but nothing can be pulled or synced from a
    // tracking branch that does not exist yet.
    const noUpstream = 'This branch has no upstream yet';
    return const {
      RepositorySyncCommand.pull: noUpstream,
      RepositorySyncCommand.pullRebase: noUpstream,
      RepositorySyncCommand.pullMerge: noUpstream,
      RepositorySyncCommand.sync: noUpstream,
      RepositorySyncCommand.forcePushWithLease: noUpstream,
      RepositorySyncCommand.forcePush: noUpstream,
    };
  }

  /// Every sync verb routes to the same call its keyboard shortcut and menu
  /// item use — the group adds a surface, never a second implementation.
  void _invokeSyncCommand(RepositorySyncCommand command) {
    final settings = ref.read(appSettingsProvider);
    switch (command) {
      case RepositorySyncCommand.fetch:
        _fetch().ignore();
      case RepositorySyncCommand.pull:
        _pull(settings.defaultPullMode).ignore();
      case RepositorySyncCommand.pullRebase:
        _pull(PullMode.rebase).ignore();
      case RepositorySyncCommand.pullMerge:
        _pull(PullMode.merge).ignore();
      case RepositorySyncCommand.push:
        _push(followTags: settings.pushFollowTags).ignore();
      case RepositorySyncCommand.pushSetUpstream:
        _push(setUpstream: true).ignore();
      case RepositorySyncCommand.pushTags:
        _push(followTags: true).ignore();
      case RepositorySyncCommand.forcePushWithLease:
        _push(force: PushForce.withLease).ignore();
      case RepositorySyncCommand.forcePush:
        _push(force: PushForce.force).ignore();
      case RepositorySyncCommand.sync:
        _sync(settings.defaultPullMode).ignore();
    }
  }

  void _invokePrimaryRepositoryAction(
    RepositoryPrimaryActionKind kind, {
    required GitStatus? status,
    required PendingOp? pending,
  }) {
    switch (kind) {
      case RepositoryPrimaryActionKind.resolve:
        final conflicts = status?.conflicted;
        if (conflicts == null || conflicts.isEmpty) return;
        final path = conflicts.first.path;
        setState(() {
          _selectionKind = _SectionKind.conflict;
          _selectedPaths = {path};
          _selectionAnchor = path;
        });
        return;
      case RepositoryPrimaryActionKind.continueOperation:
        if (pending != null && pending != PendingOp.none) {
          _continuePending(pending).ignore();
          return;
        }
        final stagedCount = status?.staged.length ?? 0;
        if (stagedCount > 0) _openCommitComposer();
        return;
      case RepositoryPrimaryActionKind.sync:
        _sync(ref.read(appSettingsProvider).defaultPullMode).ignore();
        return;
      case RepositoryPrimaryActionKind.pull:
        _pull(ref.read(appSettingsProvider).defaultPullMode).ignore();
        return;
      case RepositoryPrimaryActionKind.push:
        _push(
          followTags: ref.read(appSettingsProvider).pushFollowTags,
        ).ignore();
        return;
      case RepositoryPrimaryActionKind.publish:
        _push(setUpstream: true).ignore();
        return;
      case RepositoryPrimaryActionKind.fetch:
        _fetch().ignore();
        return;
      // Other screens' primary verbs. `resolvePrimaryRepositoryAction` — the
      // only source of this screen's kind — never produces them, and they are
      // listed rather than defaulted so adding a kind is a compile error here
      // until someone decides what this screen should do with it.
      case RepositoryPrimaryActionKind.fetchAndPrune:
      case RepositoryPrimaryActionKind.stash:
      case RepositoryPrimaryActionKind.addWorktree:
      case RepositoryPrimaryActionKind.refresh:
      case RepositoryPrimaryActionKind.createRequest:
        return;
    }
  }

  /// Opens a tree-selected file's diff in the existing diff panel — or the
  /// conflict pane for an unmerged path (0009 H5): tree selections skip
  /// `reconcile`, so nothing downstream would rehome a mis-sectioned one.
  void _openFileFromTree(
    String path, {
    required bool staged,
    required bool untracked,
    required bool conflict,
  }) {
    setState(() {
      _selectionKind = conflict
          ? _SectionKind.conflict
          : untracked
          ? _SectionKind.untracked
          : staged
          ? _SectionKind.staged
          : _SectionKind.unstaged;
      _selectedPaths = {path};
      _selectionAnchor = path;
    });
  }

  Widget _commitBar(
    BuildContext context,
    GitStatus status,
    CommitComposerController composerController, {
    required String? policyAdvisory,
  }) {
    final stagedCount = status.staged.length;
    // Accent (not secondary) while that button still has work. Asked of the
    // actual unstaged/untracked lists, not a count comparison — a
    // partially-staged file is one record in BOTH lists, so `stagedCount <
    // files.length` read a lone mixed file as "everything staged" while its
    // worktree half still had changes to stage.
    final hasUnstaged =
        status.unstaged.isNotEmpty || status.untracked.isNotEmpty;
    final hasStaged = stagedCount > 0;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: CommitComposer(
              controller: composerController,
              presentation: CommitComposerPresentation.collapsed,
              branchLabel: status.branch.head ?? 'Detached HEAD',
              policyAdvisory: policyAdvisory,
              onAccept: (push) =>
                  _acceptCommitComposer(composerController, push),
              onExpand: _openCommitComposer,
            ),
          ),
          const SizedBox(width: 8),
          AppPushButton(
            controlSize: ControlSize.large,
            secondary: !hasStaged,
            // The mirror of Stage All — nothing staged, nothing to do.
            onPressed: hasStaged ? _unstageAll : null,
            child: const Text('Unstage All'),
          ),
          const SizedBox(width: 8),
          AppPushButton(
            controlSize: ControlSize.large,
            secondary: !hasUnstaged,
            // Same gate as the repository.stageAll shortcut — nothing left
            // to stage dims the button instead of running a no-op (0009 L8).
            onPressed: hasUnstaged ? _stageAll : null,
            child: const Text('Stage All'),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (context) {
              // Teach the live focus-composer chord (⌘G default, remaps
              // honored) on the button that does the same thing (0009 L10).
              final bindings = ref.watch(
                keymapProvider,
              )['repository.focusCommit'];
              final suffix = (bindings == null || bindings.isEmpty)
                  ? ''
                  : ' (${bindings.first.label})';
              return MacosTooltip(
                message: 'Focus commit composer$suffix',
                child: AppPushButton(
                  controlSize: ControlSize.large,
                  secondary: !hasStaged,
                  onPressed: hasStaged
                      ? () {
                          composerController.expand();
                          _openCommitComposer();
                        }
                      : null,
                  child: const Text('Commit…'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    GitStatus status, {
    required RepositoryWorkspacePrefs preferences,
    required ValueChanged<RepositoryWorkspacePrefs>? onPreferencesChanged,
    required RepositoryContextSupplement? supplement,
  }) {
    final list = _fileList(
      context,
      status,
      preferences: preferences,
      onPreferencesChanged: onPreferencesChanged,
      supplement: supplement,
    );
    // Popped out: the diff moved into the floating window, so the file list
    // gets its full width back instead of splitting the row with it.
    final Widget? panel = _popout
        ? null
        : _reviewOpen
        ? _multiFileReviewPanel()
        : _isMultiSelect
        ? _multiSelectPanel(context)
        : _selectedConflict != null
        ? _conflictPanel(context, _selectedConflict!)
        : _selected != null
        ? _diffPanel(context)
        : null;
    if (panel == null) return list;
    return ResizablePanePair(
      leading: list,
      trailing: panel,
      extent: preferences.navigatorWidth,
      minExtent: RepositoryWorkspacePrefs.minNavigatorWidth,
      maxExtent: RepositoryWorkspacePrefs.maxNavigatorWidth,
      trailingFloor: 320,
      defaultExtent: RepositoryWorkspacePrefs.defaultNavigatorWidth,
      collapsed: preferences.navigatorCollapsed,
      semanticLabel: 'Resize repository change navigator',
      onCommit: (width) => onPreferencesChanged?.call(
        preferences.copyWith(navigatorWidth: width),
      ),
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

  Widget _multiFileReviewPanel() => MultiFileReviewView(
    repoPath: repoPath,
    controller: _reviewController,
    onClose: () => setState(() => _reviewOpen = false),
    onStage: _stageMany,
    onUnstage: _unstageMany,
    onDiscard: _discardMany,
    onDelete: _discardUntrackedMany,
    onIgnore: _addToGitignoreMany,
    onResolveOurs: (paths) => _resolveMany(paths, useOurs: true),
    onResolveTheirs: (paths) => _resolveMany(paths, useOurs: false),
  );

  Widget _conflictPanel(BuildContext context, String path) {
    final contentAsync = ref.watch(conflictFileProvider((repoPath, path)));
    final sides = conflictSideLabels(
      ref.watch(pendingOpProvider(repoPath)).value,
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
              // Ours is the left side, theirs the right — the arrows carry
              // the same left/right convention the conflict view's columns
              // do. The words come from conflictSideLabels so a rebase says
              // Onto/Commit instead of the misleading merge vocabulary.
              InlineActionButton(
                label: 'Use ${sides.ours}',
                icon: CupertinoIcons.arrow_left,
                onPressed: () => _resolve(path, useOurs: true),
              ),
              const SizedBox(width: 6),
              InlineActionButton(
                label: 'Use ${sides.theirs}',
                icon: CupertinoIcons.arrow_right,
                onPressed: () => _resolve(path, useOurs: false),
              ),
              const SizedBox(width: 6),
              InlineActionButton(
                label: 'Mark Resolved',
                icon: CupertinoIcons.check_mark_circled,
                tooltip:
                    'git add — keep the working-tree file (your manual edit) '
                    'as the resolution.',
                onPressed: () => _stage(path),
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
            loading: () => const DiffPending(),
            error: (err, _) => DiffFailure(err),
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
              DiffViewControls(
                split: _diffSplit,
                ignoreWhitespace: _diffIgnoreWs,
                expandedContext: _diffExpandContext,
                blame: _diffBlame,
                onToggleSplit: () {
                  setState(() => _diffSplit = !_diffSplit);
                  _persistDiffPrefs();
                },
                onPrevious: () => _moveFileSelection(-1),
                onNext: () => _moveFileSelection(1),
                onToggleWhitespace: () {
                  setState(() => _diffIgnoreWs = !_diffIgnoreWs);
                  _persistDiffPrefs();
                },
                onToggleContext: () {
                  setState(() => _diffExpandContext = !_diffExpandContext);
                  _persistDiffPrefs();
                },
                onToggleBlame: () => setState(() => _diffBlame = !_diffBlame),
                onPopOut: () => setState(() => _popout = true),
                onClose: _clearSelection,
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: diffAsync.when(
            loading: () => const DiffPending(),
            error: (err, _) => DiffFailure(err),
            // Per-hunk staging is available only for the unified worktree/index
            // diff of a tracked file. Split view is read-only, and a `-w` diff
            // isn't a valid apply patch — both fall back to a read-only render.
            data: (diff) {
              if (viewerFileTypeFor(path).preview == PreviewKind.image) {
                final file = parseUnifiedDiff(diff);
                final added = untracked || file?.change == DiffFileChange.added;
                final deleted = file?.change == DiffFileChange.deleted;
                return ImageDiffView(
                  repoPath: repoPath,
                  displayPath: path,
                  beforePath: added ? null : file?.oldPath ?? path,
                  beforeRevision: staged ? 'HEAD' : ':0',
                  afterPath: deleted ? null : file?.newPath ?? path,
                  afterRevision: staged ? ':0' : null,
                  canOpenExternally: !deleted,
                );
              }
              if (_diffSplit) {
                return Column(
                  children: [
                    _warningBanner(
                      context,
                      'Line actions require Unified view because split rows '
                      'do not map one-to-one to the patch.',
                    ),
                    Expanded(child: SplitDiffView(diff: diff)),
                  ],
                );
              }
              if (_diffIgnoreWs) {
                return Column(
                  children: [
                    _warningBanner(
                      context,
                      'Line actions require whitespace-exact diff mode.',
                    ),
                    Expanded(child: DiffView(diff: diff)),
                  ],
                );
              }
              // Blame gutter: fetched only while the toggle is on, and only for
              // the tracked unified diff. Renders as soon as it lands; the diff
              // shows immediately without waiting on it.
              final blame = _diffBlame
                  ? ref.watch(blameProvider((repoPath, path))).value
                  : null;
              return HunkDiffView(
                diff: diff,
                staged: staged,
                onAction: _applyHunk,
                onSelectionAction: _applySelection,
                selectionDisabledReason: _diffBlame
                    ? 'Line actions are unavailable while blame annotations '
                          'are shown.'
                    : null,
                blame: blame,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Stages / unstages / discards a single hunk by rebuilding a one-hunk patch
  /// and feeding it to `git apply`. Refreshes status and the *specific* diff key
  /// so the pane reflects the change immediately.
  Future<void> _applyHunk(
    DiffFile file,
    DiffHunk hunk,
    HunkAction action,
  ) async {
    // Captured before any await: the discard confirm dialog below spans one,
    // and a watcher-driven _syncSelectionToStatus can clear the selection
    // while it's up — the late `_selected!` fallback read then threw.
    final selected = _selected;
    if (selected == null) return;
    final git = ref.read(gitServiceProvider);
    final patch = buildHunkPatch(file, hunk);

    if (action == HunkAction.discard) {
      final ok = await confirmAction(
        context,
        title: 'Discard hunk',
        message:
            'Discard this hunk from the working tree? The file is '
            'snapshotted first — press ⌘Z to undo, or restore it later from '
            'the Recovery view.',
        confirmLabel: 'Discard',
        destructive: true,
      );
      if (!ok) return;
    }
    if (!mounted) return;

    await runGuarded(() {
      switch (action) {
        case HunkAction.stage:
          return git.applyPatch(repoPath, patch, cached: true, reverse: false);
        case HunkAction.unstage:
          return git.applyPatch(repoPath, patch, cached: true, reverse: true);
        case HunkAction.discard:
          // The one apply that destroys content — snapshotted, so it is
          // ⌘Z-able like every other discard (see [GitService.discardHunk]).
          return git.discardHunk(
            repoPath,
            patch,
            path: file.newPath ?? file.oldPath ?? selected.path,
          );
      }
    });
    // runGuarded's `finally` now runs the refresh unconditionally (success
    // or failure) — mounted-guarded, marking the own-mutation (so the
    // watcher's echo tick is suppressed rather than triggering a redundant
    // refetch) and invalidating status plus the selected file's diff key.
  }

  Future<void> _applySelection(
    DiffFile file,
    String patch,
    int selectedLineCount,
    HunkAction action,
  ) async {
    final selected = _selected;
    if (selected == null) return;
    final git = ref.read(gitServiceProvider);
    if (action == HunkAction.discard) {
      final ok = await confirmAction(
        context,
        title: 'Discard selected lines',
        message:
            'Discard $selectedLineCount selected changed '
            '${selectedLineCount == 1 ? 'line' : 'lines'} from the working '
            'tree? The file is snapshotted first, so this remains undoable.',
        confirmLabel: 'Discard Selection',
        destructive: true,
      );
      if (!ok) return;
    }
    if (!mounted) return;
    await runGuarded(() {
      switch (action) {
        case HunkAction.stage:
          return git.applySelectionPatch(repoPath, patch, reverse: false);
        case HunkAction.unstage:
          return git.applySelectionPatch(repoPath, patch, reverse: true);
        case HunkAction.discard:
          return git.discardSelectionPatch(
            repoPath,
            patch,
            path: file.newPath ?? file.oldPath ?? selected.path,
          );
      }
    });
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

  List<_StatusRow> _statusRows(GitStatus status) {
    if (identical(status, _rowsForStatus)) return _rows;
    final rows = deriveRepoChangeRows(status);
    _rowsForStatus = status;
    _rows = rows;
    return rows;
  }

  Widget _fileList(
    BuildContext context,
    GitStatus status, {
    required RepositoryWorkspacePrefs preferences,
    required ValueChanged<RepositoryWorkspacePrefs>? onPreferencesChanged,
    required RepositoryContextSupplement? supplement,
  }) {
    final canonical = _statusRows(status);
    final effectiveFilter = _changeFilter.copyWith(
      grouping: preferences.grouping,
    );
    final reviewed = {
      for (final item in _reviewController.value.reviewed) item.pathIdentity,
    };
    final result = filterRepoChangeRows(
      canonical,
      effectiveFilter,
      reviewedPaths: reviewed,
    );
    final rows = result.rows;
    final selectionSection = _selectionKind;
    final visibleSelected = <String>{
      for (final row in rows)
        if (row is _FileRow && row.section == selectionSection) row.file.path,
    };
    final hiddenSelectionCount = _selectedPaths
        .difference(visibleSelected)
        .length;
    final changes = status.isClean
        ? RepositoryCleanState(
            branchLabel: status.branch.isDetached
                ? 'Detached HEAD'
                : status.branch.head ?? 'Unborn branch',
            supplement: supplement,
          )
        : Focus(
            focusNode: _listFocus,
            onKeyEvent: _onListKey,
            // The staging banner overlays the top of the list, but only while a file
            // drag is live (idle it's zero-size and the list is fully interactive).
            // It dispatches to the same bulk stage/unstage the row icons and context
            // menu use, so drag-to-stage stays consistent with every other path.
            child: DeselectOnEmptyClick(
              onDeselect: _clearSelection,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ListView.builder(
                      controller: _listScroll,
                      itemCount: rows.length,
                      itemBuilder: (context, index) =>
                          _statusRow(context, rows[index], rows),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: StagingDropBanner(
                      onStage: _stageMany,
                      onUnstage: _unstageMany,
                    ),
                  ),
                ],
              ),
            ),
          );
    return RepoChangeNavigator(
      filterController: _changeFilterController,
      filter: effectiveFilter,
      onFilterChanged: (next) {
        setState(() => _changeFilter = next);
        if (next.grouping != preferences.grouping) {
          onPreferencesChanged?.call(
            preferences.copyWith(grouping: next.grouping),
          );
        }
      },
      visibleCount: result.visibleFiles,
      totalCount: result.totalFiles,
      hiddenSelectionCount: hiddenSelectionCount,
      onRevealSelection: () {
        _changeFilterController.clear();
        setState(() {
          _changeFilter = RepoChangeFilter(grouping: preferences.grouping);
        });
      },
      onClearSelection: _clearSelection,
      selectedCount: _selectedPaths.length,
      onReviewSelected: _selectedPaths.length > 1
          ? () {
              final items = reviewItemsFromRows(
                canonical,
                paths: _selectedPaths,
                section: _selectionKind,
              );
              _reviewController.open(items);
              setState(() => _reviewOpen = items.isNotEmpty);
            }
          : null,
      onReviewAllVisible: result.visibleFiles == 0
          ? null
          : () {
              // ALL visible rows across every section (0009 M13) — the old
              // first-section-only walk silently dropped the rest of the
              // list the button claimed to review.
              final visible = result.rows.whereType<_FileRow>().toList();
              _reviewController.open(
                reviewItemsFromRows(
                  result.rows,
                  paths: visible.map((row) => row.file.path).toSet(),
                ),
              );
              setState(() => _reviewOpen = true);
            },
      changes: changes,
    );
  }

  _SectionKind _kindOfFileRow(_FileRow row) => row.section;

  /// " (Space)"-style tooltip suffix for [actionId]'s first binding under the
  /// LIVE keymap (remaps honored), or empty when unbound (0009 L10).
  String _bindingSuffix(String actionId) {
    final bindings = ref.watch(keymapProvider)[actionId];
    if (bindings == null || bindings.isEmpty) return '';
    return ' (${bindings.first.label})';
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
      _selectionNotifier.select(rows, path, kind, toggle: meta, range: shift);
      // Popout only ever shows a single non-conflict file's diff; drop it
      // once the selection no longer looks like that (a conflict, none, or
      // several files) rather than leaving it showing a stale file.
      if (kind == _SectionKind.conflict || _selectedPaths.length != 1) {
        _popout = false;
      }
    });
  }

  /// Select-on-drag (see [DragItemDraggable.onDragSelect]): picking a file row
  /// up selects exactly it, like a plain click — ignoring ⌘/⇧ (a drag must
  /// never toggle or range-extend) — and no-ops when the row is already part
  /// of the current selection, since the drag then carries the whole
  /// multi-selection and collapsing it would change the payload's meaning.
  void _selectForDrag(String path, _SectionKind kind) {
    if (_isPathSelected(path, kind)) return;
    _listFocus.requestFocus();
    setState(() {
      _selectionKind = kind;
      _selectedPaths = {path};
      _selectionAnchor = path;
      // Same rule as _handleRowTap: the popout only shows a single
      // non-conflict file; this selection IS a single file, so it can stay.
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
  List<ContextMenuEntry> _buildMenuEntries(
    _SectionKind kind,
    List<String> paths,
  ) {
    final many = paths.length > 1;
    final n = paths.length;
    final entries = <ContextMenuEntry>[];

    switch (kind) {
      case _SectionKind.untracked:
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.plus_circle_fill,
            label: many ? 'Stage $n Files' : 'Stage',
            onTap: () => many ? _stageMany(paths) : _stage(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.eye_slash,
            label: many ? 'Add $n Files to .gitignore' : 'Add to .gitignore',
            onTap: () => many
                ? _addToGitignoreMany(paths)
                : _addToGitignore(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.trash_fill,
            label: many ? 'Delete $n Files' : 'Delete Untracked File',
            onTap: () => many
                ? _discardUntrackedMany(paths)
                : _discardUntracked(paths.single),
          ),
        ]);
      case _SectionKind.unstaged:
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.plus_circle_fill,
            label: many ? 'Stage $n Files' : 'Stage',
            onTap: () => many ? _stageMany(paths) : _stage(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.arrow_uturn_left_circle_fill,
            label: many ? 'Discard Changes in $n Files' : 'Discard Changes',
            onTap: () => many ? _discardMany(paths) : _discard(paths.single),
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
            icon: CupertinoIcons.minus_circle_fill,
            label: many ? 'Unstage $n Files' : 'Unstage',
            onTap: () => many ? _unstageMany(paths) : _unstage(paths.single),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.arrow_uturn_left_circle_fill,
            label: many
                ? 'Discard Staged Changes in $n Files'
                : 'Discard Staged Changes',
            onTap: () =>
                many ? _discardStagedMany(paths) : _discardStaged(paths.single),
          ),
        ]);
      case _SectionKind.conflict:
        final sides = conflictSideLabels(
          ref.read(pendingOpProvider(repoPath)).value,
        );
        entries.addAll([
          ContextMenuItem(
            icon: CupertinoIcons.arrow_left_circle_fill,
            label: many
                ? 'Resolve $n Using ${sides.ours}'
                : 'Resolve Using ${sides.ours}',
            onTap: () => many
                ? _resolveMany(paths, useOurs: true)
                : _resolve(paths.single, useOurs: true),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.arrow_right_circle_fill,
            label: many
                ? 'Resolve $n Using ${sides.theirs}'
                : 'Resolve Using ${sides.theirs}',
            onTap: () => many
                ? _resolveMany(paths, useOurs: false)
                : _resolve(paths.single, useOurs: false),
          ),
          // A hand-edited conflict is kept with `git add`, not by taking one
          // whole side (0009 H6).
          ContextMenuItem(
            icon: CupertinoIcons.check_mark_circled,
            label: many ? 'Mark $n Resolved' : 'Mark Resolved',
            onTap: () => many ? _stageMany(paths) : _stage(paths.single),
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
        onTap: () => copyToClipboard(paths.map(_absolutePath).join('\n')),
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
    }
    entries.add(
      ContextMenuItem(
        icon: CupertinoIcons.square_arrow_up,
        label: many ? 'Open $n Files' : 'Open file',
        onTap: () {
          if (ref.read(connectionProvider).isLocal) {
            openFiles(paths.map(_absolutePath).toList());
          } else {
            for (final path in paths) {
              ref
                  .read(remoteEditServiceProvider.notifier)
                  .openRemoteFile(repoPath, path);
            }
          }
        },
      ),
    );
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
        child: Tappable(
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
            color: _isPathSelected(file.path, _SectionKind.conflict)
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
                  icon: CupertinoIcons.arrow_left_circle_fill,
                  tooltip: 'Resolve using ours',
                  size: 16,
                  color: MacosColors.systemBlueColor,
                  onPressed: () => _resolve(file.path, useOurs: true),
                ),
                ToolIconButton(
                  icon: CupertinoIcons.arrow_right_circle_fill,
                  tooltip: 'Resolve using theirs',
                  size: 16,
                  color: MacosColors.systemPurpleColor,
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
    // Dragging a row that's part of the current selection carries the whole
    // selection; otherwise just this one path. Feeds the files→Stashes
    // partial-stash drop. Conflict rows (handled above) aren't draggable —
    // git stash refuses a tree with unmerged paths.
    final dragPaths = _isPathSelected(file.path, kind)
        ? _orderedSelectedPaths(rows, kind)
        : [file.path];
    return DragItemDraggable(
      // fromStaged makes the drag-to-stage banner directional: a staged row can
      // only be unstaged, everything else only staged. Immediate (mouse-first)
      // drag — see DragItemDraggable; plain clicks still select.
      item: DragFiles(dragPaths, fromStaged: kind == _SectionKind.staged),
      immediate: true,
      // Picking a row up selects it (canonical engine contract) — unless it's
      // already in the selection, which the drag is carrying whole.
      onDragSelect: () => _selectForDrag(file.path, kind),
      child: KeyedSubtree(
        key: _rowKeyFor(file.path, kind),
        child: GestureDetector(
          onTap: () {
            _listFocus.requestFocus();
            _handleRowTap(rows, file.path, kind);
          },
          onSecondaryTapUp: (d) =>
              _handleRowSecondaryTap(rows, file.path, kind, d.globalPosition),
          child: Container(
            color: _isPathSelected(file.path, kind)
                ? AppTheme.rowSelectionTint
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
                if (file.isSubmodule) ...[
                  const SizedBox(width: 6),
                  const SubmoduleChip(),
                ],
                if (row.discardable)
                  ToolIconButton(
                    // An untracked file has nothing tracked to revert to — delete
                    // it outright (trash icon) rather than "discard" (revert icon).
                    icon: file.isUntracked
                        ? CupertinoIcons.trash_fill
                        : CupertinoIcons.arrow_uturn_left_circle_fill,
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
                      ? CupertinoIcons.minus_circle_fill
                      : CupertinoIcons.plus_circle_fill,
                  tooltip:
                      '${staged ? 'Unstage' : 'Stage'}'
                      '${_bindingSuffix('repository.toggleStage')}',
                  size: 17,
                  color: staged
                      ? MacosColors.systemOrangeColor
                      : MacosColors.systemGreenColor,
                  onPressed: () =>
                      staged ? _unstage(file.path) : _stage(file.path),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
