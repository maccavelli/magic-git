import 'dart:async';
import 'dart:isolate';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/commit_graph.dart';
import '../../core/git/git_service.dart';
import '../../core/git/log_search.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/utils/display_error.dart';
import '../branches/create_tag_sheet.dart';
import '../common/actions.dart';
import '../common/branch_switch.dart';
import '../common/busy_action.dart';
import '../common/commit_patch_view.dart';
import '../common/context_menu.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/prompt_text_sheet.dart';
import '../common/repository_context.dart';
import '../common/resizable_master_detail.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../dnd/deselect.dart';
import '../dnd/drag_item.dart';
import '../dnd/drag_state.dart';
import '../forge/forge_prefs.dart';
import '../worktrees/add_worktree_sheet.dart';
import '../worktrees/worktree_tabs.dart';
import 'commit_graph_view.dart';
import 'history_minimap.dart';
import 'log_filter.dart';
import 'rebase_sheet.dart';
import 'ref_chip.dart';

/// Commit history: a selectable commit list on the left, the selected commit's
/// patch on the right.
class HistoryView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether the History panel is the visible one. Scoped keyboard shortcuts
  /// (copy SHA, checkout, rebase, …) install only while active, so they don't
  /// fire from a background page kept mounted in the shell's IndexedStack.
  final bool isActive;

  /// Opens this view in its own native macOS window. Non-null only in the
  /// main app shell (which owns the window bridge); the popped-out window
  /// itself passes null — no popout-from-popout, and no button rendered.
  final VoidCallback? onPopOut;

  const HistoryView({
    super.key,
    required this.repoPath,
    this.isActive = true,
    this.onPopOut,
  });

  @override
  ConsumerState<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends ConsumerState<HistoryView>
    with WidgetsBindingObserver, BusyActionState {
  // Multi-selection over commit hashes, following the macOS list-selection
  // conventions (same scheme as RepoStatusView's file rows): plain click
  // replaces the selection, ⌘-click toggles a row in/out, ⇧-click extends a
  // contiguous range from the anchor. [_selectionAnchor] is the fixed end of
  // a shift-range; [_selectionCursor] is the moving end — the row keyboard
  // navigation continues from.
  Set<String> _selectedHashes = {};
  String? _selectionAnchor;
  String? _selectionCursor;

  // Guards against opening a second interactive-rebase sheet while one is
  // already up: each sheet captures its own commit-list snapshot, so if the
  // first rebase completes and rewrites hashes before the second is
  // dismissed, the second would operate against stale/nonexistent hashes.
  bool _rebaseSheetOpen = false;

  // History search/filter: a debounced message filter, an all-branches
  // toggle, and the advanced criteria (author / date range / path / hide
  // merges) revealed by the filter toggle. When any is active the panel uses
  // [logSearchProvider] — every criterion maps to a `git log` flag, so
  // filtering is server-side and complete, never limited to loaded rows.
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final TextEditingController _authorController = TextEditingController();
  final TextEditingController _afterController = TextEditingController();
  final TextEditingController _beforeController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();

  // Keyboard navigation of the commit list: the list takes focus on a row tap,
  // then ↑/↓ walk the selection through the commits (⇧↑/⇧↓ extend a range),
  // scrolling each into view.
  final FocusNode _commitFocus = FocusNode(debugLabel: 'commit-list');
  final ScrollController _commitScroll = ScrollController();
  final Map<String, GlobalKey> _commitRowKeys = {};

  // Right-click menu on commit rows. One controller for the whole list.
  final ContextMenuOverlay _contextMenu = ContextMenuOverlay();

  // Bumped on every ScrollMetricsNotification from the commit list — the
  // minimap's signal for "content dimensions exist/changed". A
  // ScrollController only notifies on scroll, so first layout, list-length
  // changes, and window resizes are invisible to it.
  final ValueNotifier<int> _scrollMetricsTick = ValueNotifier(0);

  // ⌘-scroll zoom needs the list's own scrolling out of the way: while ⌘ is
  // held the ListView gets NeverScrollableScrollPhysics, whose
  // shouldAcceptUserOffset=false makes the Scrollable skip registering for
  // pointer-scroll events — so the zoom Listener's registration wins.
  // Tracked via a HardwareKeyboard handler because no widget has focus
  // guarantees over a hovering-only mouse.
  bool _metaDown = false;

  // PointerPanZoomUpdate.scale is cumulative for the whole trackpad-pinch
  // gesture; zoom applies the per-event ratio against this running value.
  double _lastPinchScale = 1.0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addObserver(this);
  }

  static const _ownMutationSuppressWindow = Duration(seconds: 3);

  bool _onHardwareKey(KeyEvent event) {
    // Only the active view needs to track ⌘ (it gates this list's scroll
    // physics for ⌘-scroll zoom). Skipping when offscreen avoids rebuilding a
    // hidden History tab on every ⌘-shortcut pressed anywhere in the app.
    if (widget.isActive) _syncMeta();
    return false; // observe only — never consume the event
  }

  /// Re-derives [_metaDown] from the live keyboard state. Called from the key
  /// handler AND from pointer hover/scroll on the list, because macOS can drop
  /// a ⌘ key-up when focus is stolen mid-press (a native menu opening, ⌘Tab):
  /// the handler then never fires again and a stuck-true [_metaDown] would
  /// freeze the list (NeverScrollableScrollPhysics) until ⌘ is pressed again.
  /// Any mouse interaction over the list re-syncs first, so scroll self-heals.
  void _syncMeta() {
    final meta = HardwareKeyboard.instance.isMetaPressed;
    if (meta != _metaDown && mounted) {
      setState(() => _metaDown = meta);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Focus left the app (⌘Tab, Mission Control): a ⌘ key-up may land
    // elsewhere, so drop the held state rather than trust a stale true.
    if (state != AppLifecycleState.resumed && _metaDown && mounted) {
      setState(() => _metaDown = false);
    }
  }

  /// The filter field's parsed grammar: free text plus `author:` / `file:` /
  /// `sha:` / `after:` / `before:` terms (see [parseLogFilter]). Where a typed
  /// term and the matching structured field are both set, the typed term wins
  /// — it's the one the user is looking at as they type.
  LogFilter _typed = LogFilter.empty;
  String _author = '';
  String _since = '';
  String _until = '';
  String _path = '';
  bool _hideMerges = false;
  // All-branches scope lives on [appSettingsProvider.historyAllBranches] so a
  // late prefs load cannot leave LogQuery desynced from the warmed provider
  // key (initState-only capture froze the AppSettings default of `true`).
  bool _filtersExpanded = false;
  Timer? _searchDebounce;

  /// Branch/tag revision scope from Branches handoff; null = ordinary HEAD/`--all`.
  String? _revisionScope;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _authorController.dispose();
    _afterController.dispose();
    _beforeController.dispose();
    _pathController.dispose();
    _commitFocus.dispose();
    _commitScroll.dispose();
    _scrollMetricsTick.dispose();
    _contextMenu.dispose();
    super.dispose();
  }

  // The effective criteria: a typed `key:` term overrides the structured
  // field of the same name, which supplies the value when no term was typed.
  String? get _effGrep => _typed.message;
  String? get _effAuthor => _typed.author ?? (_author.isEmpty ? null : _author);
  String? get _effSince => _typed.since ?? (_since.isEmpty ? null : _since);
  String? get _effUntil => _typed.until ?? (_until.isEmpty ? null : _until);
  String? get _effPath => _typed.path ?? (_path.isEmpty ? null : _path);

  String? get _effSha => _typed.sha;

  /// True when any narrowing criterion is active. The all-branches toggle is
  /// a view *scope* rather than a filter, but both route the panel through
  /// [logSearchProvider] and disqualify the top row as HEAD.
  bool get _hasQueryFilters =>
      _effGrep != null ||
      _effAuthor != null ||
      _effSince != null ||
      _effUntil != null ||
      _effPath != null ||
      _effSha != null ||
      _hideMerges;

  bool get _filtering =>
      _hasQueryFilters || ref.read(appSettingsProvider).historyAllBranches;

  /// The provider key for the currently displayed history. The paging depth is
  /// deliberately not part of it — it lives on [LogSearchNotifier], so scrolling
  /// deeper extends the walk in place rather than minting a new key that
  /// re-walks from the top. Changing any criterion here IS a new key, and so
  /// correctly starts again at page one with a fresh spinner: rows the new
  /// filter was never applied to must never linger on screen.
  LogQuery get _query => (
    repoPath: widget.repoPath,
    grep: _effGrep,
    author: _effAuthor,
    since: _effSince,
    until: _effUntil,
    path: _effPath,
    sha: _effSha,
    noMerges: _hideMerges,
    all:
        _revisionScope == null &&
        ref.read(appSettingsProvider).historyAllBranches,
    revision: _revisionScope,
  );

  GlobalKey _commitRowKeyFor(String hash) =>
      _commitRowKeys.putIfAbsent(hash, GlobalKey.new);

  /// The selection's single hash when exactly one commit is selected — the
  /// target for single-commit actions (checkout, reset, the diff pane…),
  /// which are meaningless or ambiguous against a multi-selection.
  String? get _soleSelectedHash =>
      _selectedHashes.length == 1 ? _selectedHashes.first : null;

  /// Resets the selection state. Callers wrap in setState (or are already in
  /// a state-mutation path such as didUpdateWidget).
  void _clearSelection() {
    _selectedHashes = {};
    _selectionAnchor = null;
    _selectionCursor = null;
  }

  /// The selected commits in on-screen (newest-first) order. A selection
  /// survives filter changes, so hashes not present in the displayed list are
  /// simply omitted here.
  List<GitCommit> _orderedSelected(List<GitCommit>? commits) => [
    for (final c in commits ?? const <GitCommit>[])
      if (_selectedHashes.contains(c.hash)) c,
  ];

  /// The contiguous run of hashes (in on-screen order) between [anchor] and
  /// [target], inclusive of both — the result of a shift-click range-select.
  /// Falls back to just [target] if either endpoint isn't in the displayed
  /// list (e.g. the anchor was filtered out since it was set).
  Set<String> _rangeBetween(
    List<GitCommit> commits,
    String anchor,
    String target,
  ) {
    final i = commits.indexWhere((c) => c.hash == anchor);
    final j = commits.indexWhere((c) => c.hash == target);
    if (i == -1 || j == -1) return {target};
    final lo = i < j ? i : j;
    final hi = i < j ? j : i;
    return {for (var k = lo; k <= hi; k++) commits[k].hash};
  }

  /// Handles a plain click, ⌘-click, or ⇧-click on a commit row — the macOS
  /// list-selection conventions: plain click replaces the selection; ⌘-click
  /// toggles this row in/out of it; ⇧-click extends a contiguous range from
  /// the anchor.
  void _handleRowTap(String hash) {
    _commitFocus.requestFocus();
    final commits = _lastCommits ?? const <GitCommit>[];
    final keys = HardwareKeyboard.instance;
    setState(() {
      if (keys.isMetaPressed) {
        if (_selectedHashes.contains(hash)) {
          // ⌘-click on a selected row removes it. The removed hash must NOT
          // stay the range anchor / keyboard cursor — a following ⇧-click or
          // ⇧-arrow would range from it and silently re-include the row just
          // deselected (mis-targeting the bulk cherry-pick/revert that acts on
          // the selection). Re-seat any endpoint that pointed at it onto a
          // still-selected row (newest-first on-screen order = a stable end).
          _selectedHashes = {..._selectedHashes}..remove(hash);
          if (_selectedHashes.isEmpty) {
            _selectionAnchor = null;
            _selectionCursor = null;
          } else {
            final remaining = _orderedSelected(commits);
            final seat = remaining.isNotEmpty
                ? remaining.first.hash
                : _selectedHashes.first;
            if (!_selectedHashes.contains(_selectionAnchor)) {
              _selectionAnchor = seat;
            }
            if (!_selectedHashes.contains(_selectionCursor)) {
              _selectionCursor = seat;
            }
          }
        } else {
          _selectedHashes = {..._selectedHashes, hash};
          _selectionAnchor = hash;
          _selectionCursor = hash;
        }
      } else if (keys.isShiftPressed && _selectionAnchor != null) {
        _selectedHashes = _rangeBetween(commits, _selectionAnchor!, hash);
        // Anchor deliberately stays put — repeated shift-clicks extend or
        // contract from the same fixed end, matching Finder.
        _selectionCursor = hash;
      } else {
        _selectedHashes = {hash};
        _selectionAnchor = hash;
        _selectionCursor = hash;
      }
    });
  }

  /// Select-on-drag (see [DragItemDraggable.onDragSelect]): picking a commit
  /// row up selects exactly it, like a plain click — but deliberately ignores
  /// ⌘/⇧ (a drag must never range-extend or toggle), and no-ops when the row
  /// is already selected so dragging out of a multi-selection keeps it intact.
  void _selectForDrag(String hash) {
    if (_selectedHashes.contains(hash)) return;
    _commitFocus.requestFocus();
    setState(() {
      _selectedHashes = {hash};
      _selectionAnchor = hash;
      _selectionCursor = hash;
    });
  }

  void _moveCommitSelection(int dir, {bool extend = false}) {
    final commits = _lastCommits;
    if (commits == null || commits.isEmpty) return;
    final fromHash = _selectionCursor;
    var current = -1;
    if (fromHash != null) {
      current = commits.indexWhere((c) => c.hash == fromHash);
    }
    final next = stepSelection(current, dir, commits.length);
    final hash = commits[next].hash;
    setState(() {
      if (extend && _selectionAnchor != null) {
        _selectedHashes = _rangeBetween(commits, _selectionAnchor!, hash);
      } else {
        _selectedHashes = {hash};
        _selectionAnchor = hash;
      }
      _selectionCursor = hash;
    });
    ensureRowVisible(_commitRowKeyFor(hash));
  }

  KeyEventResult _onCommitKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || busy) {
      return KeyEventResult.ignored;
    }
    // Keys typed into a text field (the commit-filter bar) belong to the
    // field, not the list — the same gate PanelShortcuts applies to the
    // ⌘-bindings (Esc in the filter must not clear the commit selection).
    if (PanelShortcuts.textInteractionHasFocus()) {
      return KeyEventResult.ignored;
    }
    final extend = HardwareKeyboard.instance.isShiftPressed;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.keyJ:
        _moveCommitSelection(1, extend: extend);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyK:
        _moveCommitSelection(-1, extend: extend);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Canonical deselect — see dnd/deselect.dart for the Esc layering
        // (overlay closes first, then a live drag cancels, then this).
        return escDeselect(
          hasSelection: _selectedHashes.isNotEmpty,
          clear: () => setState(_clearSelection),
        );
    }
    return KeyEventResult.ignored;
  }

  /// The [GitCommit] for the sole selected hash in the currently-displayed
  /// list, or null if the selection isn't exactly one commit (or it scrolled
  /// out of a filtered list). Needed by cherry-pick/rebase, which act on the
  /// commit object rather than a bare hash.
  GitCommit? _selectedCommitIn(List<GitCommit>? commits) {
    final hash = _soleSelectedHash;
    if (hash == null) return null;
    for (final c in commits ?? const <GitCommit>[]) {
      if (c.hash == hash) return c;
    }
    return null;
  }

  /// Debounces syncing the filter state from ALL the text controllers, so a
  /// remote `git log` doesn't fire on every keystroke. One timer, one full
  /// sync: a per-field pending mutation would be lost when typing moves to
  /// the next field inside the debounce window and cancels the timer.
  void _debounceFilters() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(kInputDebounce, () {
      if (!mounted) return;
      setState(() {
        _typed = parseLogFilter(_searchController.text);
        _author = _authorController.text.trim();
        _since = _afterController.text.trim();
        _until = _beforeController.text.trim();
        _path = _pathController.text.trim();
      });
    });
  }

  /// Resets every filter criterion (not the all-branches scope — that has
  /// its own toggle and represents what's shown, not what's excluded).
  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _authorController.clear();
    _afterController.clear();
    _beforeController.clear();
    _pathController.clear();
    setState(() {
      _typed = LogFilter.empty;
      _author = '';
      _since = '';
      _until = '';
      _path = '';
      _hideMerges = false;
    });
  }

  // Memoized lane graph + ref decorations. Both are recomputed only when their
  // source list *instance* changes (Riverpod hands back the same list across
  // rebuilds until the provider is invalidated), so merely selecting a commit
  // no longer re-lays-out the whole graph or re-groups every ref.
  List<GitCommit>? _lastCommits;
  String? _lastHeadSha;
  CommitGraph? _graph;
  List<GitRef>? _lastRefs;
  Map<String, List<GitRef>>? _decorations;

  /// Last successfully loaded refs for this repo. [refsProvider] is autoDispose
  /// and is invalidated on every git-state tick; during the reload
  /// `AsyncValue.value` is often null, and the history pop-out used to paint
  /// a bare list (`?? const []`) for the whole round trip — or forever if the
  /// proxied for-each-ref failed. Keep the last good list so branch/tag chips
  /// stay visible.
  List<GitRef> _stableRefs = const [];

  /// Commit-count above which lane layout is built on a background isolate
  /// rather than synchronously on the UI thread. `CommitGraph.build` is roughly
  /// linear, so small histories lay out in well under a frame and the isolate's
  /// copy-in/copy-out overhead isn't worth paying; large paged-in histories
  /// (the case that janks) cross the boundary instead.
  static const int _graphIsolateThreshold = 2000;

  /// Bumped on every async build kick-off and on repo change; a completing
  /// off-isolate build whose id no longer matches is stale and dropped.
  int _graphBuildId = 0;

  /// The commits instance an off-isolate build is currently in flight for, so
  /// repeated rebuilds with the same list don't schedule duplicate builds.
  List<GitCommit>? _pendingGraphCommits;

  /// Returns the laid-out graph for [commits], always synchronously. Small
  /// histories are laid out inline and memoized on list identity. Large ones
  /// are laid out on a background isolate; until that lands we keep serving the
  /// previous graph (or [CommitGraph.empty] on first load) so the frame never
  /// blocks on layout — the view repaints via `setState` when it arrives.
  CommitGraph _graphFor(List<GitCommit> commits, {String? headSha}) {
    if (identical(commits, _lastCommits) &&
        headSha == _lastHeadSha &&
        _graph != null) {
      return _graph!;
    }
    _lastCommits = commits;
    _lastHeadSha = headSha;
    if (commits.length < _graphIsolateThreshold) {
      _pendingGraphCommits = null;
      return _graph = CommitGraph.build(commits, headSha: headSha);
    }
    if (!identical(commits, _pendingGraphCommits)) {
      _pendingGraphCommits = commits;
      final id = ++_graphBuildId;
      unawaited(_buildGraphAsync(commits, id, headSha: headSha));
    }
    return _graph ?? CommitGraph.empty;
  }

  Future<void> _buildGraphAsync(
    List<GitCommit> commits,
    int id, {
    String? headSha,
  }) async {
    final graph = await Isolate.run(
      () => CommitGraph.build(commits, headSha: headSha),
    );
    // Superseded by a newer list (or a repo switch) while we were building.
    if (!mounted || id != _graphBuildId) return;
    setState(() {
      _lastCommits = commits;
      _pendingGraphCommits = null;
      _graph = graph;
    });
  }

  Map<String, List<GitRef>> _decorationsFor(List<GitRef> refs) {
    if (!identical(refs, _lastRefs) || _decorations == null) {
      _lastRefs = refs;
      _decorations = refsByCommit(refs);
    }
    return _decorations!;
  }

  /// Prefer the latest successful [refsProvider] payload; fall back to the
  /// last good list while loading/errored so decorations don't blink out.
  List<GitRef> _refsForDecorations() {
    final async = ref.watch(refsProvider(widget.repoPath));
    final latest = async.value;
    if (latest != null) {
      _stableRefs = latest;
      return latest;
    }
    return _stableRefs;
  }

  CommitGraph? _densitySource;
  List<double>? _density;

  /// Per-row activity for the minimap's silhouette: how busy the calendar day
  /// each commit landed on was, as a share of the busiest day in the loaded
  /// history (0..1). Memoized on graph identity — the minimap rebuilds on
  /// every scroll tick, and this walks the whole list.
  List<double> _densityFor(CommitGraph graph) {
    if (identical(graph, _densitySource) && _density != null) return _density!;
    final rows = graph.rows;
    final days = List<String>.filled(rows.length, '');
    final perDay = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      // The date is ISO 8601 (`%aI`), so the calendar day is its first 10
      // characters — no parsing needed.
      final date = rows[i].commit.date;
      final day = date.length >= 10 ? date.substring(0, 10) : date;
      days[i] = day;
      perDay[day] = (perDay[day] ?? 0) + 1;
    }
    var busiest = 0;
    for (final count in perDay.values) {
      if (count > busiest) busiest = count;
    }
    _densitySource = graph;
    return _density = busiest == 0
        ? List<double>.filled(rows.length, 0)
        : [for (final day in days) (perDay[day] ?? 0) / busiest];
  }

  @override
  void didUpdateWidget(HistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      _clearSelection();
      // Per-hash row keys are meaningless for another repo's hashes; without
      // this, a long session hopping between repos retains one GlobalKey per
      // commit ever displayed.
      _commitRowKeys.clear();
      _lastCommits = null;
      _graph = null;
      // Invalidate any in-flight off-isolate layout for the old repo so it
      // can't land and paint the wrong history.
      _pendingGraphCommits = null;
      _graphBuildId++;
      _lastRefs = null;
      _decorations = null;
      _stableRefs = const [];
      _densitySource = null;
      _density = null;
      // Stale cumulative pinch ratio from a previous repo would corrupt the
      // first frame of a new pinch here.
      _lastPinchScale = 1.0;
      // The depth resets itself: a different repo is a different [LogQuery],
      // hence a different notifier, which starts again at page one.
    }
  }

  String get repoPath => widget.repoPath;

  void _refresh() {
    // `_run` calls this right after an awaited op with no further check of
    // its own, and touching `ref` after the widget is disposed throws.
    if (!mounted) return;
    // The shared post-mutation refresh (see refreshAfterMutation) — includes
    // reflog/snapshots so an open Recovery sheet reflects a tab-side mutation.
    refreshAfterMutation(ref, repoPath);
  }

  /// [movesHead] ops (reset, amend, branch-from) clear the diff selection on
  /// success because the selected commit may no longer exist / be meaningful.
  Future<void> _run(Future<void> Function() op, {bool movesHead = false}) =>
      runGuarded(op, onSuccess: movesHead ? _clearSelection : null);

  @override
  void refreshAfterAction() => _refresh();

  GitCommit? _commitFor(String hash) {
    for (final c in _lastCommits ?? const <GitCommit>[]) {
      if (c.hash == hash) return c;
    }
    return null;
  }

  // The unfiltered list is `git log HEAD`, so its first row is the current
  // HEAD commit. Under any active filter/scope the displayed list is a
  // subset whose top row need not be HEAD, so refuse to treat any commit as
  // HEAD then: "Amend last commit" rewrites the *real* HEAD, not the shown
  // commit, and must never be offered against a non-HEAD top row.
  bool _isHead(String hash) =>
      !_filtering &&
      _lastCommits?.isNotEmpty == true &&
      _lastCommits!.first.hash == hash;

  /// A single-field text prompt (branch name, mainline number) — the shared
  /// sheet, see [promptText].
  Future<String?> _promptText(
    String title, {
    required String placeholder,
    String initial = '',
    String? description,
  }) => promptText(
    context,
    title,
    placeholder: placeholder,
    initial: initial,
    description: description,
  );

  /// Resolves the mainline parent for a merge commit: prompts (default 1) when
  /// [commit] is a merge, otherwise returns null (no `-m`).
  Future<int?> _mainlineFor(GitCommit commit) async {
    if (!commit.isMerge) return null;
    final v = await _promptText(
      'Mainline parent',
      placeholder: '1',
      initial: '1',
      description:
          'This is a merge commit — pick which parent counts as the '
          'mainline (1 = the branch that was merged into).',
    );
    if (v == null) return null;
    return int.tryParse(v) ?? 1;
  }

  GitService get _git => ref.read(gitServiceProvider);

  double get _zoom =>
      ref.read(appSettingsProvider.select((s) => s.historyZoom));

  /// Nudges the persisted zoom factor; the notifier clamps and no-ops at the
  /// bounds. Additive for discrete steps (⌘=/⌘−, scroll ticks).
  void _adjustZoom(double delta) {
    ref.read(appSettingsProvider.notifier).setHistoryZoom(_zoom + delta);
  }

  /// Multiplicative zoom for trackpad pinches, which report scale ratios.
  void _scaleZoom(double factor) {
    ref.read(appSettingsProvider.notifier).setHistoryZoom(_zoom * factor);
  }

  Future<void> _actCheckout(String hash) async {
    final ok = await confirmAction(
      context,
      title: 'Checkout commit',
      message:
          'Check out $hash? You will be on a detached HEAD — create a branch '
          'to keep any new commits.',
      confirmLabel: 'Checkout',
    );
    if (!ok || busy || !mounted) return;
    // The same dirty-tree guardrail a branch checkout gets (stash / carry /
    // cancel): a detached checkout overwrites the working tree just the same,
    // and this path used to skip the guard — the user got git's raw
    // "would be overwritten" error instead of the stash offer. runGuarded's
    // always-refresh matters too: the guard's stash step can succeed while
    // the checkout fails, and that intermediate state must land on screen.
    await runGuarded(() async {
      final switched = await guardedBranchSwitch(
        context,
        ref,
        repoPath,
        () => _git.checkout(repoPath, hash),
      );
      // Only an actual switch invalidates the selection — a cancelled guard
      // dialog leaves everything as it was.
      if (switched && mounted) setState(_clearSelection);
    });
  }

  Future<void> _actBranchFrom(String hash) async {
    final name = await _promptText(
      'New branch from commit',
      placeholder: 'branch name',
      description:
          'Creates a branch starting at the selected commit and checks it '
          'out.',
    );
    if (name != null) {
      await _run(() => _git.branchFrom(repoPath, name, hash), movesHead: true);
    }
  }

  /// Branch from a commit into a NEW checkout, leaving this one untouched — the
  /// "I need to look at this without losing my place" flow.
  Future<void> _actWorktreeFrom(String hash) async {
    await showMacosSheet<void>(
      context: context,
      builder: (_) => AddWorktreeSheet(
        repoPath: repoPath,
        initialCommitish: hash,
        // Non-null so the sheet opens on "new branch" (the commit is the start
        // point, not a branch to check out) with the name left for the user.
        initialBranchName: '',
      ),
    );
    if (mounted) _refresh();
  }

  /// Tags a commit via the shared Create Tag sheet (annotated toggle,
  /// message, push-after-create) — prefilled with this commit as the target.
  Future<void> _actCreateTagAt(GitCommit commit) async {
    final created = await showMacosSheet<bool>(
      context: context,
      builder: (_) => CreateTagSheet(
        repoPath: repoPath,
        initialRef: commit.hash,
        initialRefLabel: '${commit.shortHash} — ${commit.subject}',
      ),
    );
    if (created == true && mounted) _refresh();
  }

  Future<void> _actCherryPick(GitCommit commit) async {
    final label = 'git cherry-pick ${commit.shortHash}';
    if (commit.isMerge) {
      final m = await _mainlineFor(commit);
      if (m == null) return;
      await runLogged(
        label,
        (log) async => log.logResult(
          label,
          await _git.cherryPick(repoPath, commit.hash, mainline: m),
        ),
      );
    } else {
      await runLogged(
        label,
        (log) async =>
            log.logResult(label, await _git.cherryPick(repoPath, commit.hash)),
      );
    }
  }

  Future<void> _actRevert(GitCommit commit) async {
    final ok = await confirmAction(
      context,
      title: 'Revert commit',
      message: 'Create a commit that undoes ${commit.shortHash}?',
      confirmLabel: 'Revert',
    );
    if (!ok) return;
    final m = await _mainlineFor(commit);
    if (commit.isMerge && m == null) return; // cancelled the mainline prompt
    final label = 'git revert ${commit.shortHash}';
    await runLogged(
      label,
      (log) async => log.logResult(
        label,
        await _git.revert(repoPath, commit.hash, mainline: m),
      ),
    );
  }

  /// Cherry-picks a multi-selection, applying oldest→newest so each commit
  /// lands on top of the previous one — the order the range was authored in.
  /// A conflict throws a [GitException] out of the loop, so the batch stops
  /// at the first conflicting commit (already-applied picks stand, matching
  /// `git cherry-pick a b c` semantics) and [_runLogged] surfaces the error
  /// and refreshes into the pending-op/conflict state.
  ///
  /// Merge commits are excluded up front by the menu (each needs its own
  /// mainline choice — pick those individually).
  Future<void> _actCherryPickMany(List<GitCommit> newestFirst) async {
    if (newestFirst.length == 1) return _actCherryPick(newestFirst.single);
    final oldestFirst = newestFirst.reversed.toList();
    final n = oldestFirst.length;
    final ok = await confirmAction(
      context,
      title: 'Cherry-pick $n commits',
      message:
          'Apply the $n selected commits (oldest first) onto the current '
          'branch? The batch stops at the first conflict.',
      confirmLabel: 'Cherry-pick',
    );
    if (!ok) return;
    await runLogged('git cherry-pick ($n commits)', (log) async {
      for (final c in oldestFirst) {
        log.logResult(
          'git cherry-pick ${c.shortHash}',
          await _git.cherryPick(repoPath, c.hash),
        );
      }
    });
  }

  /// Reverts a multi-selection, newest→oldest — undoing on top of history in
  /// the reverse of the order it was made, so each revert applies cleanly
  /// against the state the next one expects. Same stop-at-first-conflict
  /// semantics as [_actCherryPickMany]; merges excluded by the menu.
  Future<void> _actRevertMany(List<GitCommit> newestFirst) async {
    if (newestFirst.length == 1) return _actRevert(newestFirst.single);
    final n = newestFirst.length;
    final ok = await confirmAction(
      context,
      title: 'Revert $n commits',
      message:
          'Create $n commits that undo the selected commits (newest first)? '
          'The batch stops at the first conflict.',
      confirmLabel: 'Revert',
    );
    if (!ok) return;
    await runLogged('git revert ($n commits)', (log) async {
      for (final c in newestFirst) {
        log.logResult(
          'git revert ${c.shortHash}',
          await _git.revert(repoPath, c.hash),
        );
      }
    });
  }

  Future<void> _actReset(String hash, ResetMode mode) async {
    final hard = mode == ResetMode.hard;
    final ok = await confirmAction(
      context,
      title: 'Reset to commit',
      message: hard
          ? 'Hard-reset to $hash? This overwrites ALL uncommitted changes — '
                'they are snapshotted first, so ⌘Z right after undoes the '
                'whole reset.'
          : 'Move HEAD to $hash (${mode.name})?',
      confirmLabel: 'Reset',
    );
    if (ok) {
      await _run(() => _git.reset(repoPath, hash, mode: mode), movesHead: true);
    }
  }

  Future<void> _actAmend() async {
    final ok = await confirmAction(
      context,
      title: 'Amend last commit',
      message:
          'Amend HEAD with the currently staged changes? This rewrites the '
          'commit — avoid it if the commit is already pushed.',
      confirmLabel: 'Amend',
    );
    if (ok) await _run(() => _git.amendCommit(repoPath), movesHead: true);
  }

  Future<void> _copySha(String hash) async {
    await Clipboard.setData(ClipboardData(text: hash));
  }

  /// Copies every selected commit's full SHA, one per line, in on-screen
  /// (newest-first) order. Selection hashes that fell out of the displayed
  /// list keep a stable fallback order so ⌘C never silently drops one.
  Future<void> _copySelectedShas() async {
    final ordered = _orderedSelected(_lastCommits);
    final hashes = ordered.length == _selectedHashes.length
        ? [for (final c in ordered) c.hash]
        : _selectedHashes.toList();
    if (hashes.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: hashes.join('\n')));
  }

  /// Handles a right-click on a commit row: if the click landed outside the
  /// current selection, it collapses to just that row first — same as Finder,
  /// the menu always acts on what ends up selected, not whatever was selected
  /// before the click. Then shows the menu for whichever selection results.
  void _handleRowSecondaryTap(GitCommit commit, Offset globalPosition) {
    if (!_selectedHashes.contains(commit.hash)) {
      setState(() {
        _selectedHashes = {commit.hash};
        _selectionAnchor = commit.hash;
        _selectionCursor = commit.hash;
      });
    }
    final ordered = _orderedSelected(_lastCommits);
    if (ordered.isEmpty) return;
    _contextMenu.show(
      context,
      globalPosition,
      _commitMenuEntries(ordered),
      width: 250,
    );
  }

  /// The commit actions for [selection] (in on-screen, newest-first order) —
  /// the single source of truth consumed by both the right-click menu and the
  /// diff-header pulldown, so the two can never drift apart. Single-commit
  /// verbs interpolate the target hash; a multi-selection gets the bulk verbs
  /// (cherry-pick N / revert N / copy N SHAs).
  List<ContextMenuEntry> _commitMenuEntries(List<GitCommit> selection) {
    // Every mutating item is disabled while an operation is already
    // mid-flight, so a second tap can't queue up behind it — the same busy
    // gating the pulldown menu has always applied.
    final canAct = !busy;
    if (selection.length == 1) {
      final commit = selection.single;
      final hash = commit.hash;
      final short = commit.shortHash;
      final canRebase = canAct && commit.parents.isNotEmpty;
      return [
        ContextMenuItem(
          icon: CupertinoIcons.arrow_right_circle,
          label: 'Checkout $short',
          enabled: canAct,
          onTap: () => _actCheckout(hash),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_branch,
          label: 'Branch from $short…',
          enabled: canAct,
          onTap: () => _actBranchFrom(hash),
        ),
        // Same as above, but into a separate checkout — so you can start from
        // this commit without abandoning whatever is in your working tree.
        ContextMenuItem(
          icon: kWorktreeIcon,
          label: 'Branch from $short in a new worktree…',
          enabled: canAct,
          onTap: () => _actWorktreeFrom(hash),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.tag,
          label: 'Tag $short…',
          enabled: canAct,
          onTap: () => _actCreateTagAt(commit),
        ),
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: CupertinoIcons.plus_circle,
          label: 'Cherry-pick $short',
          enabled: canAct,
          onTap: () => _actCherryPick(commit),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_uturn_left,
          label: 'Revert $short',
          enabled: canAct,
          onTap: () => _actRevert(commit),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.list_number,
          label: 'Interactive rebase from here…',
          enabled: canRebase,
          disabledTooltip: commit.parents.isEmpty
              ? 'The root commit has no parent to rebase onto'
              : null,
          onTap: () => _actRebaseFrom(commit),
        ),
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: CupertinoIcons.gobackward,
          label: 'Reset to $short — soft',
          enabled: canAct,
          onTap: () => _actReset(hash, ResetMode.soft),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.gobackward,
          label: 'Reset to $short — mixed',
          enabled: canAct,
          onTap: () => _actReset(hash, ResetMode.mixed),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.gobackward,
          label: 'Reset to $short — hard',
          enabled: canAct,
          iconColor: MacosColors.systemRedColor,
          onTap: () => _actReset(hash, ResetMode.hard),
        ),
        const ContextMenuDivider(),
        if (_isHead(hash))
          ContextMenuItem(
            icon: CupertinoIcons.pencil,
            label: 'Amend last commit',
            enabled: canAct,
            onTap: _actAmend,
          ),
        ContextMenuItem(
          icon: CupertinoIcons.doc_on_clipboard,
          label: 'Copy SHA',
          onTap: () => _copySha(hash),
        ),
      ];
    }

    final n = selection.length;
    // Bulk cherry-pick/revert can't span a merge commit: each merge needs
    // its own mainline choice, which a batch can't prompt for sensibly.
    final hasMerge = selection.any((c) => c.isMerge);
    const mergeTooltip =
        'The selection contains a merge commit — act on it individually to '
        'choose its mainline parent';
    return [
      ContextMenuItem(
        icon: CupertinoIcons.plus_circle,
        label: 'Cherry-pick $n commits',
        enabled: canAct && !hasMerge,
        disabledTooltip: hasMerge ? mergeTooltip : null,
        onTap: () => _actCherryPickMany(selection),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_uturn_left,
        label: 'Revert $n commits',
        enabled: canAct && !hasMerge,
        disabledTooltip: hasMerge ? mergeTooltip : null,
        onTap: () => _actRevertMany(selection),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_clipboard,
        label: 'Copy $n SHAs',
        onTap: _copySelectedShas,
      ),
    ];
  }

  /// Opens the interactive-rebase editor for the commits from [commit] up to
  /// HEAD (rebased onto [commit]'s parent). The sheet performs the rebase and
  /// refreshes the repo-scoped providers itself.
  ///
  /// Always resolves the range from a fresh, *unfiltered* walk — never from
  /// `_lastCommits`, which is whatever the panel is currently displaying and
  /// can be a search/grep- or all-branches-filtered subset. Building the
  /// rebase todo from a filtered list would silently drop every real,
  /// non-matching commit between `onto` and HEAD, since the rebase replaces
  /// history with exactly the `commits` list passed in.
  ///
  /// The walk is `git log <parent>..HEAD` — exactly the commits the rebase
  /// would rewrite, however deep the selected commit sits. (A depth-capped
  /// `git log HEAD` was used before, capped at the *filtered* walk's depth:
  /// a commit found via search 3 000 commits down was then "not found" in a
  /// 200-deep raw log, and the dialog wrongly claimed it wasn't part of the
  /// branch at all.) The range contains [commit] itself precisely when it IS
  /// a HEAD ancestor — commits reachable from HEAD but not from the parent —
  /// so the membership check below doubles as the ancestry test, verified
  /// against real git.
  Future<void> _actRebaseFrom(GitCommit commit) async {
    // Also gated on `busy` — the same flag cherry-pick/revert/etc. use via
    // `_run`/`_runLogged` — so a rebase can't start while another History
    // mutation is mid-flight, and vice versa: those actions won't fire while
    // this sheet is open, since `busy` stays set for its whole lifetime.
    if (busy || _rebaseSheetOpen || commit.parents.isEmpty) return;
    List<GitCommit> commits;
    try {
      // The cap only bounds a pathological range — a todo of thousands of
      // rows is unusable well before git objects to it.
      commits = await _git.log(
        repoPath,
        revision: '${commit.parents.first}..HEAD',
        maxCount: 10000,
      );
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, displayError(e));
      return;
    }
    if (!mounted) return;
    final idx = commits.indexWhere((c) => c.hash == commit.hash);
    if (idx < 0) {
      // The range from its parent to HEAD doesn't contain it, so HEAD does
      // not descend from it (reachable only via the all-branches view). The
      // HEAD..commit range this rebase would rewrite doesn't exist — say so
      // instead of no-op'ing.
      await showErrorDialog(
        context,
        '${commit.shortHash} isn\'t part of the current branch\'s history. '
        'Interactive rebase rewrites the commits between HEAD and the one you '
        'pick, so pick a commit that HEAD descends from.',
      );
      return;
    }
    // commits[0..idx] are HEAD..selected (newest first); the todo is oldest-first.
    final slice = commits.sublist(0, idx + 1);
    // git rejects `pick <merge-hash>` outright, which would strand the repo in
    // a paused rebase the user never asked for. Hand-linearizing the range
    // (dropping the merges from the todo, like native `rebase -i` does) isn't
    // safe either: this todo is built from a linear slice of the log, and for
    // a DAG that slice can omit side-branch commits whose content would then
    // be silently lost. Refuse up front with an explanation instead.
    if (slice.any((c) => c.parents.length > 1)) {
      await showErrorDialog(
        context,
        'The range from ${commit.shortHash} to HEAD contains a merge commit. '
        'Interactive rebase across merges isn\'t supported — pick a commit '
        'with only linear history above it.',
      );
      return;
    }
    final included = slice.reversed.toList();
    setState(() => _rebaseSheetOpen = true);
    try {
      // holdBusyWhile: the sheet owns the interaction and refreshes itself;
      // the panel underneath just has to stay inert until it closes.
      await holdBusyWhile(
        () => showMacosSheet<void>(
          context: context,
          builder: (_) => EscapeDismissible(
            child: RebaseSheet(
              repoPath: repoPath,
              onto: commit.parents.first,
              commits: included,
            ),
          ),
        ),
      );
    } finally {
      _rebaseSheetOpen = false;
    }
    // A completed rebase rewrites hashes for the whole range — the selected
    // commit (if it was in that range) no longer exists, so the diff pane
    // would otherwise keep requesting a stale hash and surface a raw git
    // error instead of just clearing.
    if (mounted) setState(_clearSelection);
  }

  /// Warms the commit-patch cache for the newest few commits whenever a fresh
  /// log lands, so selecting one renders instantly. Commit patches are
  /// immutable (hash-keyed, cached in the large immutable LRU tier) so each is
  /// fetched at most once per session — no throttle needed; the fetches ride
  /// the executor's concurrent read lane and can't delay interactive commands.
  static const int _prefetchMaxCommits = 8;

  void _prefetchCommitPatches(List<GitCommit>? commits) {
    if (commits == null || !widget.isActive) return;
    for (final c in commits.take(_prefetchMaxCommits)) {
      // `.ignore()`: a prefetch failure must never surface — selecting the
      // commit simply fetches it live, exactly as before.
      ref
          .read(
            commitDiffProvider((
              widget.repoPath,
              c.hash,
              AppSettingsNotifier.defaultDiffContext,
            )).future,
          )
          .ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch so a late prefs load rebuilds onto the correct LogQuery key.
    final allBranches = ref.watch(
      appSettingsProvider.select((s) => s.historyAllBranches),
    );
    // One-shot handoff from Branches: seed revision scope for this mount only.
    ref.listen(historyNavigationIntentProvider, (prev, next) {
      if (next == null) return;
      if (next.repoPath != widget.repoPath) return;
      setState(() => _revisionScope = next.revision);
      ref.read(historyNavigationIntentProvider.notifier).clear();
    });
    final intent = ref.watch(historyNavigationIntentProvider);
    if (intent != null &&
        intent.repoPath == widget.repoPath &&
        _revisionScope != intent.revision) {
      // Apply on first paint if listen missed a pre-mounted intent.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final still = ref.read(historyNavigationIntentProvider);
        if (still != null && still.repoPath == widget.repoPath) {
          setState(() => _revisionScope = still.revision);
          ref.read(historyNavigationIntentProvider.notifier).clear();
        }
      });
    }
    final filtering = _hasQueryFilters || allBranches || _revisionScope != null;
    final query = (
      repoPath: widget.repoPath,
      grep: _effGrep,
      author: _effAuthor,
      since: _effSince,
      until: _effUntil,
      path: _effPath,
      sha: _effSha,
      noMerges: _hideMerges,
      all: _revisionScope == null && allBranches,
      revision: _revisionScope,
    );
    // Event-driven refresh: each coalesced remote-change tick re-fetches history
    // and refs when git's own state moves (.git/refs, HEAD, index).
    ref.listen(repoWatchProvider(widget.repoPath), (previous, next) {
      final event = next.value;
      if (event == null) return;
      if (ref
          .read(ownMutationTrackerProvider)
          .isRecent(widget.repoPath, event.at, _ownMutationSuppressWindow)) {
        return;
      }
      if (event.touchesGitState) {
        refreshAfterMutation(ref, widget.repoPath);
      }
    });

    // Warm the patch cache as fresh history lands — the newest commits are the
    // ones overwhelmingly likely to be inspected.
    ref.listen(logSearchProvider(query), (previous, next) {
      _prefetchCommitPatches(next.value);
      // Prune stale selections: after a refresh or filter change, hashes that
      // are no longer in the displayed list should be dropped so the diff pane
      // doesn't keep fetching a ghost commit. Only prune when new data has
      // landed (not during loading) and when the selection actually references
      // hashes absent from the new list.
      final landed = next.value;
      if (landed != null) {
        final live = {for (final c in landed) c.hash};
        // Prune GlobalKey map: keys for commits no longer displayed are useless
        // and, over a long session with many page-loads, accumulate without
        // bound. Retain only keys whose hashes are still in the visible list.
        if (_commitRowKeys.length > live.length * 2) {
          _commitRowKeys.removeWhere((hash, _) => !live.contains(hash));
        }
        if (_selectedHashes.isNotEmpty) {
          final pruned = _selectedHashes.intersection(live);
          if (pruned.length != _selectedHashes.length) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _selectedHashes = pruned;
                if (_selectionAnchor != null &&
                    !pruned.contains(_selectionAnchor)) {
                  _selectionAnchor = pruned.isNotEmpty ? pruned.first : null;
                }
                if (_selectionCursor != null &&
                    !pruned.contains(_selectionCursor)) {
                  _selectionCursor = pruned.isNotEmpty ? pruned.last : null;
                }
              });
            });
          }
        }
      }
    });
    final logAsync = ref.watch(logSearchProvider(query));
    // Ref decorations are best-effort: if for-each-ref never lands, show a bare
    // graph — but keep the last successful list across reloads (pop-out ticks
    // invalidate refs often; see [_refsForDecorations]).
    final decorations = _decorationsFor(_refsForDecorations());

    // Loading a deeper page no longer changes the provider key, so the rows
    // already on screen (and the scroll offset) survive it on their own: the
    // notifier keeps the previous value under the AsyncLoading. A *criteria*
    // change is still a new key, and so still blanks to a spinner — rows the new
    // filter was never applied to must never linger.
    final commits = logAsync.value;
    if (commits != null && commits.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final connection = ref.read(connectionProvider);
        if (connection.sessionEpoch <= 0) return;
        ref
            .read(repositoryContextSupplementCacheProvider.notifier)
            .publish(
              RepositoryContextSupplementKey(
                repositoryIdentity: repositoryContextIdentityKey(
                  backend: connection.backend.name,
                  connectionId: connection.connectionId,
                  repositoryPath: widget.repoPath,
                ),
                sessionEpoch: connection.sessionEpoch,
              ),
              RepositoryContextSupplement(
                recentCommitLabel: commits.first.subject,
              ),
            );
      });
    }
    // The walk ran out — there is no next page, so the load-more sentinel is not
    // built at all. Decided by git's own row count (every criterion is applied
    // by git, so a short page means "no more matches", not "the client filtered
    // some out"), and tracked on the notifier because the count alone stops
    // being conclusive once a page is stitched on: a boundary dedupe can shorten
    // the list without meaning the history ended.
    // Reads the notifier directly rather than watching it — the `exhausted`
    // field is mutable state on the Notifier that does NOT trigger a rebuild
    // when it flips. However, the flag only transitions alongside a state
    // change (the `_walk` sets it before returning data, and `loadMore` sets
    // it before updating `state`), so the rebuild that carries the new data
    // always picks up the new flag value too.
    final exhausted =
        commits != null &&
        ref.read(logSearchProvider(query).notifier).exhausted;

    final keymap = ref.watch(keymapProvider);
    final selectedHash = _soleSelectedHash;
    final selectedCommit = _selectedCommitIn(commits);
    final hasCommits = commits?.isNotEmpty ?? false;

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    final handlers = <String, VoidCallback?>{
      'history.copySha': _selectedHashes.isEmpty ? null : _copySelectedShas,
      'history.checkout': selectedHash == null
          ? null
          : () => _actCheckout(selectedHash),
      'history.branchFrom': selectedHash == null
          ? null
          : () => _actBranchFrom(selectedHash),
      'history.cherryPick': selectedCommit == null
          ? null
          : () => _actCherryPick(selectedCommit),
      'history.rebaseFrom': selectedCommit == null
          ? null
          : () => _actRebaseFrom(selectedCommit),
      'history.amend': hasCommits ? _actAmend : null,
      'history.filter': () => _searchFocus.requestFocus(),
      'history.zoomIn': () => _adjustZoom(0.1),
      'history.zoomOut': () => _adjustZoom(-0.1),
      'history.zoomReset': () =>
          ref.read(appSettingsProvider.notifier).setHistoryZoom(1.0),
    };
    final live = widget.isActive && !busy;
    return PanelShortcuts(
      bindings: live
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: live ? handlers : const {},
      child: ResizableMasterDetail(
        paneId: PaneId.historyList,
        // The diff/detail pane hosts real patch content — keep it usable
        // when the commit list is dragged wide.
        detailFloor: 360,
        master: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _filterBar(context, filtering, allBranches: allBranches),
            if (_revisionScope != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'History of $_revisionScope',
                        style: MacosTheme.of(context).typography.caption1
                            .copyWith(color: MacosColors.systemBlueColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InlineActionButton(
                      label: 'Clear',
                      icon: CupertinoIcons.xmark_circle,
                      onPressed: () => setState(() => _revisionScope = null),
                    ),
                  ],
                ),
              ),
            ],
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(
              child: _historyBody(
                context,
                logAsync: logAsync,
                commits: commits,
                exhausted: exhausted,
                decorations: decorations,
                filtering: filtering,
              ),
            ),
            if (_hasQueryFilters) ...[
              Container(height: 1, color: MacosColors.separatorColor),
              _filterFooter(context, commits, exhausted),
            ],
          ],
        ),
        detail: _rightPane(context, commits),
      ),
    );
  }

  /// The commit list and its minimap — or the spinner/error/empty state when
  /// there's nothing to draw. [commits] is null only while the first page of a
  /// query is in flight (or after it failed); a *deeper* page keeps the
  /// already-loaded rows on screen and shows its progress in the list's
  /// trailing row instead.
  Widget _historyBody(
    BuildContext context, {
    required AsyncValue<List<GitCommit>> logAsync,
    required List<GitCommit>? commits,
    required bool exhausted,
    required Map<String, List<GitRef>> decorations,
    required bool filtering,
  }) {
    if (commits == null) {
      return logAsync.hasError
          ? _error(context, logAsync.error!)
          : const Center(child: ProgressCircle());
    }
    if (commits.isEmpty) {
      return Center(
        child: Text(
          // All-branches is a view *scope*, not a typed filter — empty still
          // means "no commits", not "no matches".
          _hasQueryFilters ? 'No matching commits' : 'No commits',
          style: MacosTheme.of(
            context,
          ).typography.body.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }
    // Extract the HEAD commit SHA from the refs list so the graph builder
    // can pin the primary branch spine to Lane 0. Without this, the spine
    // defaults to commits.first (only correct for unfiltered single-branch
    // views) and merge edges / lane assignments can be wrong.
    String? headSha;
    for (final r in _stableRefs) {
      if (r.isHead) {
        headSha = r.oid;
        break;
      }
    }
    final graph = _graphFor(commits, headSha: headSha);
    final log = ref.read(logSearchProvider(_query).notifier);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scrollMetricsTick.value++;
        return false;
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _commitList(
              context,
              graph,
              decorations,
              exhausted: exhausted,
              // A page already in flight (or one that just failed), and a whole
              // log still loading or errored, must not trigger another — see
              // [_loadMoreRow].
              canLoadMore:
                  !logAsync.isLoading &&
                  !logAsync.hasError &&
                  !log.loadingMore &&
                  !log.pageFailed,
            ),
          ),
          HistoryMinimap(
            controller: _commitScroll,
            metricsTick: _scrollMetricsTick,
            graph: graph,
            decorations: decorations,
            selected: _selectedHashes,
            density: _densityFor(graph),
          ),
        ],
      ),
    );
  }

  /// The right pane follows the selection's shape: nothing → prompt, one
  /// commit → its patch, exactly two → the diff between them (older→newer),
  /// three or more → a summary panel pointing at the bulk actions.
  Widget _rightPane(BuildContext context, List<GitCommit>? commits) {
    if (_selectedHashes.isEmpty) {
      return Center(
        child: Text(
          'Select a commit',
          style: MacosTheme.of(context).typography.body,
        ),
      );
    }
    final sole = _soleSelectedHash;
    if (sole != null) return _commitDiff(context, sole);
    final ordered = _orderedSelected(commits);
    if (_selectedHashes.length == 2 && ordered.length == 2) {
      // On-screen order is newest-first: ordered[1] is the older commit.
      return _compareView(context, older: ordered[1], newer: ordered[0]);
    }
    return _multiSelectionPanel(context, ordered);
  }

  Widget _filterBar(
    BuildContext context,
    bool filtering, {
    required bool allBranches,
  }) {
    // Advanced criteria stay visibly flagged on the toggle even while the
    // row is collapsed, so an active author/date/path filter can't be
    // forgotten behind a closed panel.
    final advancedActive =
        _author.isNotEmpty ||
        _since.isNotEmpty ||
        _until.isNotEmpty ||
        _path.isNotEmpty ||
        _hideMerges;
    // A date git would silently misread (see [dateTermProblem]) — flagged
    // here rather than rejected, because the walk has already run with git's
    // reading and THIS is the explanation for its otherwise baffling result
    // (an unfiltered list for `until:`, an empty one for `since:`). Checked on
    // the effective values, so a typed `after:`/`before:` term is covered even
    // while the advanced row is collapsed.
    final dateProblem =
        dateTermProblem(_effSince) ?? dateTermProblem(_effUntil);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: MacosTooltip(
                  message:
                      'Filter by message, or use terms: author: file: sha: '
                      'after: before:\n'
                      'e.g. rename author:mac file:lib/core/ after:2026-01-01\n'
                      'A bare commit hash (5+ characters) finds that commit\n'
                      'Words must all match; * and ? are wildcards (file:*.dart)\n'
                      'Quote values with spaces: author:"Mac Smith"',
                  child: MacosTextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    placeholder: 'Filter — message, author:, file:, sha:…',
                    placeholderStyle: kAppPlaceholderStyle,
                    decoration: kAppTextFieldDecoration,
                    focusedDecoration: kAppTextFieldFocusedDecoration,
                    onChanged: (_) => _debounceFilters(),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ToolIconButton(
                icon: CupertinoIcons.slider_horizontal_3,
                tooltip: 'Filter by author, date, or path',
                size: 16,
                color: advancedActive || _filtersExpanded
                    ? MacosColors.systemBlueColor
                    : null,
                onPressed: () =>
                    setState(() => _filtersExpanded = !_filtersExpanded),
              ),
              const SizedBox(width: 6),
              ToolIconButton(
                icon: allBranches
                    ? CupertinoIcons.square_stack_3d_up_fill
                    : CupertinoIcons.square_stack_3d_up,
                tooltip: allBranches
                    ? 'Showing all branches'
                    : 'Show all branches',
                size: 16,
                color: allBranches ? MacosColors.systemBlueColor : null,
                onPressed: () {
                  ref
                      .read(appSettingsProvider.notifier)
                      .setHistoryAllBranches(!allBranches);
                },
              ),
              const SizedBox(width: 6),
              ToolIconButton(
                icon: CupertinoIcons.arrow_counterclockwise_circle,
                tooltip: 'Recovery (reflog & snapshots)',
                size: 16,
                onPressed: () =>
                    ref.read(recoveryVisibleProvider.notifier).setVisible(true),
              ),
              if (widget.onPopOut != null) ...[
                const SizedBox(width: 6),
                ToolIconButton(
                  icon: CupertinoIcons.macwindow,
                  tooltip: 'Open History in new window',
                  size: 16,
                  onPressed: widget.onPopOut,
                ),
              ],
            ],
          ),
          if (_filtersExpanded) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: MacosTooltip(
                    message:
                        'Show only commits by this author '
                        '(matches part of a name or email)',
                    child: MacosTextField(
                      controller: _authorController,
                      placeholder: 'Author name or email',
                      placeholderStyle: kAppPlaceholderStyle,
                      decoration: kAppTextFieldDecoration,
                      focusedDecoration: kAppTextFieldFocusedDecoration,
                      onChanged: (_) => _debounceFilters(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 116,
                  child: MacosTooltip(
                    // Passed verbatim to `git log --since`, which accepts
                    // dates and phrases ("2 weeks ago") alike.
                    message:
                        'Only commits after this date — '
                        'e.g. 2024-01-31 or "2 weeks ago"',
                    child: MacosTextField(
                      controller: _afterController,
                      placeholder: 'After date',
                      placeholderStyle: kAppPlaceholderStyle,
                      decoration: kAppTextFieldDecoration,
                      focusedDecoration: kAppTextFieldFocusedDecoration,
                      onChanged: (_) => _debounceFilters(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 116,
                  child: MacosTooltip(
                    // `git log --until`, same flexible date parsing.
                    message:
                        'Only commits before this date — '
                        'e.g. 2024-01-31 or "3 days ago"',
                    child: MacosTextField(
                      controller: _beforeController,
                      placeholder: 'Before date',
                      placeholderStyle: kAppPlaceholderStyle,
                      decoration: kAppTextFieldDecoration,
                      focusedDecoration: kAppTextFieldFocusedDecoration,
                      onChanged: (_) => _debounceFilters(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: MacosTooltip(
                    message:
                        'Show only commits that touched this file '
                        'or folder',
                    child: MacosTextField(
                      controller: _pathController,
                      placeholder: 'Limit to a file or folder, e.g. lib/src/',
                      placeholderStyle: kAppPlaceholderStyle,
                      decoration: kAppTextFieldDecoration,
                      focusedDecoration: kAppTextFieldFocusedDecoration,
                      onChanged: (_) => _debounceFilters(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MacosCheckbox(
                  value: _hideMerges,
                  onChanged: (v) => setState(() => _hideMerges = v),
                ),
                const SizedBox(width: 5),
                Tappable(
                  onTap: () => setState(() => _hideMerges = !_hideMerges),
                  child: Text(
                    'Hide merges',
                    style: MacosTheme.of(context).typography.caption1,
                  ),
                ),
              ],
            ),
          ],
          if (dateProblem != null) ...[
            const SizedBox(height: 4),
            Text(
              dateProblem,
              style: MacosTheme.of(
                context,
              ).typography.caption1.copyWith(color: MacosColors.systemRedColor),
            ),
          ],
        ],
      ),
    );
  }

  /// Compact status line under a filtered list: the match count (flagging when
  /// more history is still unwalked) plus a one-click reset of every criterion.
  Widget _filterFooter(
    BuildContext context,
    List<GitCommit>? commits,
    bool exhausted,
  ) {
    final typography = MacosTheme.of(context).typography;
    final count = commits?.length;
    final label = count == null
        ? 'Filtering…'
        : !exhausted
        // The walk stopped at the current depth, so the count is a floor, not
        // a total — scrolling to the end walks further.
        ? 'First $count matching commits — scroll for more'
        : '$count matching ${count == 1 ? 'commit' : 'commits'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InlineActionButton(
            label: 'Clear filters',
            icon: CupertinoIcons.xmark,
            onPressed: _clearFilters,
          ),
        ],
      ),
    );
  }

  /// The list's trailing row while more history remains unwalked. Building it
  /// means the user scrolled to the end of what's loaded, so it asks for the
  /// next page — the request IS the scroll, so there's no button to hunt for.
  ///
  /// [canLoadMore] is false while a page is already in flight (or one just
  /// failed): the sentinel keeps being rebuilt for as long as it's on screen,
  /// and without that gate each rebuild would deepen the walk again.
  ///
  /// Not deepening the walk while a fetch is in flight is also what keeps
  /// [LogSearchNotifier.loadMore]'s `--skip` honest: it offsets past the list it
  /// is extending, so it must only ever run against a settled one.
  ///
  /// A FAILED page renders as a tappable retry row rather than the spinner: a
  /// page failure changes no provider state (the loaded rows are kept, by
  /// design), so nothing rebuilds this row on its own — [_pageAndRepaint] is
  /// what brings the failure to screen, and the row it paints is honest about
  /// there being no fetch in flight.
  Widget _loadMoreRow(double rowHeight, bool canLoadMore) {
    final log = ref.read(logSearchProvider(_query).notifier);
    if (log.pageFailed) {
      final typography = MacosTheme.of(context).typography;
      return SizedBox(
        height: rowHeight,
        child: Tappable(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _pageAndRepaint(log.retryPage);
            // retryPage cleared the flag synchronously — swap back to the
            // spinner now, not when the retried fetch settles.
            setState(() {});
          },
          child: Center(
            child: Text(
              'Couldn\'t load more commits — click to retry',
              style: typography.caption1.copyWith(
                color: MacosColors.systemBlueColor,
              ),
            ),
          ),
        ),
      );
    }
    if (canLoadMore) {
      // Post-frame: this runs inside build, and loadMore writes provider state.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _pageAndRepaint(
            ref.read(logSearchProvider(_query).notifier).loadMore,
          );
        }
      });
    }
    return SizedBox(
      height: rowHeight,
      child: const Center(child: ProgressCircle(radius: 8)),
    );
  }

  /// Runs a page fetch and repaints when it settles WITHOUT new data: a
  /// successful page changes the provider state (which rebuilds everything),
  /// but a failed one deliberately doesn't — the loaded rows stay — so the
  /// sentinel needs this nudge to swap its spinner for the retry row (and
  /// back again after a retry kicks off).
  void _pageAndRepaint(Future<void> Function() page) {
    unawaited(
      page().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  Widget _commitList(
    BuildContext context,
    CommitGraph graph,
    Map<String, List<GitRef>> decorations, {
    required bool exhausted,
    required bool canLoadMore,
  }) {
    final typography = MacosTheme.of(context).typography;
    // The zoom factor scales the whole list coherently: row extent, lane
    // geometry, node dot, and (via the TextScaler below) the text. Watched
    // here so ⌘=/⌘−/pinch rebuild the list live.
    final zoom = ref.watch(appSettingsProvider.select((s) => s.historyZoom));
    final rowHeight = kGraphRowHeight * zoom;
    final laneUnit = kLaneWidth * zoom;
    // Clamp the drawn lane *band* so a very wide graph can't crowd out the
    // text — but a topology with more than [_maxFullWidthLanes] concurrent
    // lanes (e.g. many long-lived branches active at once) must still have
    // every lane rendered somewhere in that band, just thinner, rather than
    // having the overflow lanes clipped away to invisible (silently dropping
    // a commit's line). `laneWidth` is what's actually fed to the painter;
    // it only shrinks below the full unit once the lane count exceeds the cap.
    const maxFullWidthLanes = 8;
    final laneCount = graph.laneCount < 1 ? 1 : graph.laneCount;
    final visibleLaneCount = laneCount.clamp(1, maxFullWidthLanes);
    final graphWidth = visibleLaneCount * laneUnit + laneUnit / 2;
    final laneWidth = laneCount > maxFullWidthLanes
        ? graphWidth / (laneCount + 0.5)
        : laneUnit;

    return Focus(
      focusNode: _commitFocus,
      onKeyEvent: _onCommitKey,
      child: Listener(
        // Re-sync the held-⌘ state on any hover: if a key-up was missed while
        // focus was elsewhere, moving the mouse back over the list clears the
        // stuck flag before the user tries to scroll.
        onPointerHover: (_) => _syncMeta(),
        // ⌘-scroll (mouse wheel) zooms. Registration through the pointer-
        // signal resolver only wins because the ⌘-held physics swap (below)
        // makes the Scrollable stand down — see _metaDown.
        onPointerSignal: (event) {
          // Re-sync first so a stuck _metaDown (missed key-up) can't leave the
          // list frozen: a plain scroll then flips physics back to scrollable.
          _syncMeta();
          if (event is PointerScrollEvent &&
              HardwareKeyboard.instance.isMetaPressed) {
            GestureBinding.instance.pointerSignalResolver.register(event, (e) {
              _adjustZoom(-(e as PointerScrollEvent).scrollDelta.dy / 300);
            });
          }
        },
        // Trackpads deliver two-finger scrolls AND pinches as pan-zoom
        // events (Flutter ≥3.3), not scroll signals: pinch carries a scale
        // ratio (zoom always), ⌘+two-finger-scroll carries a pan delta.
        onPointerPanZoomStart: (_) => _lastPinchScale = 1.0,
        onPointerPanZoomUpdate: (event) {
          if (event.scale != 1.0) {
            _scaleZoom(event.scale / _lastPinchScale);
            _lastPinchScale = event.scale;
          } else if (HardwareKeyboard.instance.isMetaPressed &&
              event.panDelta.dy != 0) {
            _adjustZoom(-event.panDelta.dy / 300);
          }
        },
        child: DeselectOnEmptyClick(
          onDeselect: () => setState(_clearSelection),
          child: MediaQuery(
            // Scale the list's text in lockstep with its geometry. Replaces
            // (rather than multiplies) the ambient scaler: the app is
            // desktop-only with no OS text scaling in play.
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(zoom)),
            child: ListView.builder(
              controller: _commitScroll,
              itemExtent: rowHeight,
              physics: _metaDown ? const NeverScrollableScrollPhysics() : null,
              itemCount: graph.rows.length + (exhausted ? 0 : 1),
              itemBuilder: (context, index) {
                if (index >= graph.rows.length) {
                  return _loadMoreRow(rowHeight, canLoadMore);
                }
                final row = graph.rows[index];
                final commit = row.commit;
                final selected = _selectedHashes.contains(commit.hash);
                return DragTarget<DragItem>(
                  // A branch chip dropped anywhere on a commit row opens the integrate
                  // menu; the row it lands on is just the drop affordance. Only a
                  // dragged branch (DragRef) is meaningful here — a dragged commit
                  // is bound for the nav rail, not another commit.
                  onWillAcceptWithDetails: (details) {
                    final data = details.data;
                    return data is DragRef && _canDropBranch(data.ref);
                  },
                  onAcceptWithDetails: (details) {
                    // ESC-cancelled drags release as a no-op (see DragStateNotifier).
                    if (ref.read(dragStateProvider) == null) return;
                    final data = details.data;
                    if (data is DragRef) {
                      _onBranchDropped(data.ref, details.offset);
                    }
                  },
                  builder: (context, candidate, rejected) {
                    final dropHover = candidate.isNotEmpty;
                    // The row is itself draggable (immediate: mouse-first — see
                    // DragItemDraggable) — drop a commit on the Branches tab to
                    // fork a branch, on Worktrees for a worktree, etc.
                    return DragItemDraggable(
                      item: DragCommit(commit),
                      immediate: true,
                      // Picking a row up selects it — the canonical engine
                      // contract, so the drag operand is never ambiguous.
                      onDragSelect: () => _selectForDrag(commit.hash),
                      child: GestureDetector(
                        key: _commitRowKeyFor(commit.hash),
                        onTap: () => _handleRowTap(commit.hash),
                        onSecondaryTapUp: (d) =>
                            _handleRowSecondaryTap(commit, d.globalPosition),
                        child: Container(
                          color: dropHover
                              ? MacosColors.systemGreenColor.withValues(
                                  alpha: 0.20,
                                )
                              : selected
                              ? MacosColors.systemBlueColor.withValues(
                                  alpha: 0.32,
                                )
                              : const Color(0x00000000),
                          height: rowHeight,
                          child: Row(
                            children: [
                              // Clip to the fixed band so rounding in the compressed-lane
                              // math can never paint a hair over the ref chips, subject, or
                              // author text to the right — every lane itself is still drawn
                              // (compressed via `laneWidth` above once the count exceeds
                              // the cap), never dropped.
                              ClipRect(
                                child: CustomPaint(
                                  size: Size(graphWidth, rowHeight),
                                  painter: CommitRowPainter(
                                    row,
                                    laneWidth: laneWidth,
                                    scale: zoom,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        if (commit.isMerge) ...[
                                          MacosIcon(
                                            CupertinoIcons.arrow_merge,
                                            size: 13 * zoom,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        // Subject first (Tower / Fork / GitHub Desktop): the
                                        // message is primary. Chips are intrinsically sized
                                        // (capped per chip + maxVisible) so they never compete
                                        // with the subject for flex space and collapse to
                                        // zero width — the pop-out bug that hid every badge.
                                        Expanded(
                                          child: Text(
                                            commit.subject,
                                            style: typography.body,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if ((decorations[commit.hash] ??
                                                const <GitRef>[])
                                            .isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          RefChipStrip(
                                            refs: decorations[commit.hash]!,
                                            enableDrag: true,
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${commit.shortHash}  ·  ${commit.authorName}  ·  '
                                      '${_shortDate(commit.date)}',
                                      style: typography.caption1.copyWith(
                                        color: MacosColors.systemGrayColor,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---- Drag-a-branch-to-merge / rebase -----------------------------------

  /// The current branch's short name, or null when detached — the operand every
  /// dropped-branch action is relative to.
  String? _currentBranchName() {
    for (final r in _stableRefs) {
      if (r.isHead && r.isLocalBranch) return r.shortName;
    }
    return null;
  }

  /// A drop is meaningful only when a branch is dragged and there's a current
  /// branch that differs from it (a branch can't be merged/rebased with itself).
  bool _canDropBranch(GitRef dragged) {
    final current = _currentBranchName();
    return current != null && dragged.shortName != current;
  }

  /// Opens the integrate menu at the drop point: merge [dragged] into the
  /// current branch (three modes), or rebase the current branch onto it.
  void _onBranchDropped(GitRef dragged, Offset globalPosition) {
    final current = _currentBranchName();
    if (current == null || dragged.shortName == current) return;
    final name = dragged.shortName;
    _contextMenu.show(context, globalPosition, [
      ContextMenuItem(
        icon: CupertinoIcons.arrow_merge,
        label: 'Merge $name into $current',
        onTap: () => _actMergeInto(dragged, MergeMode.normal),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_merge,
        label: 'Merge $name into $current (no-ff)',
        onTap: () => _actMergeInto(dragged, MergeMode.noFf),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_merge,
        label: 'Merge $name into $current (squash)',
        onTap: () => _actMergeInto(dragged, MergeMode.squash),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_2_squarepath,
        label: 'Rebase $current onto $name',
        onTap: () => _actRebaseOnto(dragged),
      ),
    ], width: 260);
  }

  Future<void> _actMergeInto(GitRef branch, MergeMode mode) async {
    final label = [
      'git merge',
      if (mode == MergeMode.noFf) '--no-ff',
      if (mode == MergeMode.squash) '--squash',
      branch.shortName,
    ].join(' ');
    await runLogged(
      label,
      (log) async => log.logResult(
        label,
        await _git.merge(repoPath, branch.shortName, mode: mode),
      ),
    );
  }

  Future<void> _actRebaseOnto(GitRef branch) async {
    final label = 'git rebase ${branch.shortName}';
    await runLogged(
      label,
      (log) async => log.logResult(
        label,
        await _git.rebaseOnto(repoPath, branch.shortName),
      ),
    );
  }

  Widget _commitDiff(BuildContext context, String hash) {
    final diffAsync = ref.watch(
      commitDiffProvider((
        widget.repoPath,
        hash,
        AppSettingsNotifier.defaultDiffContext,
      )),
    );
    final wrap = ref.watch(
      appSettingsProvider.select((s) => s.historyDiffWrap),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _diffHeader(context, hash, wrap),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => DiffFailure(err),
            data: (diff) => CommitPatchView(
              repoPath: widget.repoPath,
              hash: hash,
              diff: diff,
              wrap: wrap,
            ),
          ),
        ),
      ],
    );
  }

  /// The shared word-wrap toggle for every History diff header — reads and
  /// writes the persisted [AppSettings.historyDiffWrap], so all three diff
  /// surfaces (tab, pop-out window, enlarged sheet) and both windows agree.
  Widget _wrapToggle(bool wrap) => ToolIconButton(
    icon: CupertinoIcons.arrow_turn_down_left,
    tooltip: wrap ? 'Turn off word wrap' : 'Wrap long lines',
    size: 15,
    color: wrap ? MacosColors.systemBlueColor : null,
    onPressed: () =>
        ref.read(appSettingsProvider.notifier).setHistoryDiffWrap(!wrap),
  );

  /// The diff between exactly two selected commits — what [newer] adds on
  /// top of [older] (`git diff older..newer`). The pane appears the moment a
  /// second commit is ⌘/⇧-selected, matching Fork/Tower's compare-two flow.
  Widget _compareView(
    BuildContext context, {
    required GitCommit older,
    required GitCommit newer,
  }) {
    final typography = MacosTheme.of(context).typography;
    final wrap = ref.watch(
      appSettingsProvider.select((s) => s.historyDiffWrap),
    );
    final diffAsync = ref.watch(
      commitRangeDiffProvider((
        widget.repoPath,
        older.hash,
        newer.hash,
        AppSettingsNotifier.defaultDiffContext,
      )),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Comparing ${older.shortHash} → ${newer.shortHash}',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _wrapToggle(wrap),
              const SizedBox(width: 2),
              ToolIconButton(
                icon: CupertinoIcons.doc_on_clipboard,
                tooltip: 'Copy both SHAs',
                size: 14,
                onPressed: _copySelectedShas,
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => DiffFailure(err),
            data: (diff) => diff.trim().isEmpty
                ? Center(
                    child: Text(
                      'No differences between '
                      '${older.shortHash} and ${newer.shortHash}',
                      style: typography.body.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                  )
                : CommitPatchView(
                    repoPath: widget.repoPath,
                    hash: newer.hash,
                    diff: diff,
                    wrap: wrap,
                  ),
          ),
        ),
      ],
    );
  }

  /// Placeholder pane for a selection of three or more commits: a compact
  /// summary plus a pointer at the bulk actions (which live in the
  /// right-click menu).
  Widget _multiSelectionPanel(BuildContext context, List<GitCommit> ordered) {
    final typography = MacosTheme.of(context).typography;
    const previewMax = 8;
    final n = _selectedHashes.length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$n commits selected', style: typography.title3),
            const SizedBox(height: 12),
            for (final c in ordered.take(previewMax))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${c.shortHash}  ${c.subject}',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (ordered.length > previewMax)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '… and ${ordered.length - previewMax} more',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Right-click the selection for bulk actions · ⌘C copies the '
              'SHAs',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Slim bar atop the diff pane: the short hash on the left, then commit
  /// actions (word wrap, copy SHA, an actions menu) and a pop-out button.
  Widget _diffHeader(BuildContext context, String hash, bool wrap) {
    final typography = MacosTheme.of(context).typography;
    final short = hash.length > 10 ? hash.substring(0, 10) : hash;
    final commit = _commitFor(hash);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              short,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _wrapToggle(wrap),
          const SizedBox(width: 2),
          ToolIconButton(
            icon: CupertinoIcons.doc_on_clipboard,
            tooltip: 'Copy full SHA',
            size: 14,
            onPressed: () => _copySha(hash),
          ),
          const SizedBox(width: 2),
          ToolIconButton(
            icon: CupertinoIcons.arrow_up_left_arrow_down_right,
            tooltip: 'Open diff in a larger window',
            size: 15,
            onPressed: () => showMacosSheet<void>(
              context: context,
              builder: (_) => EscapeDismissible(
                child: CommitDiffSheet(repoPath: widget.repoPath, hash: hash),
              ),
            ),
          ),
          const SizedBox(width: 2),
          if (commit != null) _actionsMenu(commit),
        ],
      ),
    );
  }

  /// The diff-header pulldown, built from the same [_commitMenuEntries] the
  /// right-click menu uses — one action list, two presentations.
  Widget _actionsMenu(GitCommit commit) {
    final entries = _commitMenuEntries([commit]);
    return MacosPulldownButtonTheme(
      data: MacosPulldownButtonTheme.of(
        context,
      ).copyWith(iconColor: MacosColors.systemGrayColor),
      child: MacosPulldownButton(
        // Convention: toolbar menus use the "hamburger" (three horizontal
        // lines) glyph — the universally recognized menu affordance.
        icon: CupertinoIcons.line_horizontal_3,
        items: [
          for (final e in entries)
            switch (e) {
              ContextMenuDivider() => const MacosPulldownMenuDivider(),
              ContextMenuItem() => MacosPulldownMenuItem(
                enabled: e.enabled,
                title: Text(e.label),
                onTap: e.enabled ? e.onTap : null,
              ),
            },
        ],
      ),
    );
  }

  Widget _error(BuildContext context, Object err) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        displayError(err),
        style: MacosTheme.of(
          context,
        ).typography.body.copyWith(color: MacosColors.systemRedColor),
      ),
    ),
  );

  // Trims an ISO 8601 timestamp to the date + minute for a compact list.
  String _shortDate(String iso) =>
      iso.length >= 16 ? iso.substring(0, 16).replaceFirst('T', ' ') : iso;
}

/// A large modal presentation of a commit's diff, opened from the History
/// panel's diff-pane pop-out button for easier full-diff reading. Watches the
/// same [commitDiffProvider] so it reuses the already-fetched diff.
class CommitDiffSheet extends ConsumerWidget {
  final String repoPath;
  final String hash;

  const CommitDiffSheet({
    super.key,
    required this.repoPath,
    required this.hash,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typography = MacosTheme.of(context).typography;
    final settings = ref.watch(appSettingsProvider);
    final diffAsync = ref.watch(
      commitDiffProvider((
        repoPath,
        hash,
        AppSettingsNotifier.defaultDiffContext,
      )),
    );
    final wrap = settings.historyDiffWrap;
    final short = hash.length > 12 ? hash.substring(0, 12) : hash;
    final screen = MediaQuery.sizeOf(context);

    return MacosSheet(
      child: SizedBox(
        width: (screen.width * 0.82).clamp(600.0, 1120.0).toDouble(),
        height: (screen.height * 0.86).clamp(400.0, 880.0).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.doc_text, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Commit $short',
                      style: typography.title3,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ToolIconButton(
                    icon: CupertinoIcons.arrow_turn_down_left,
                    tooltip: wrap ? 'Turn off word wrap' : 'Wrap long lines',
                    size: 16,
                    color: wrap ? MacosColors.systemBlueColor : null,
                    onPressed: () => ref
                        .read(appSettingsProvider.notifier)
                        .setHistoryDiffWrap(!wrap),
                  ),
                  const SizedBox(width: 2),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 16,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(
              child: diffAsync.when(
                loading: () => const DiffPending(),
                error: (err, _) => DiffFailure(err),
                data: (diff) => CommitPatchView(
                  repoPath: repoPath,
                  hash: hash,
                  diff: diff,
                  wrap: wrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
