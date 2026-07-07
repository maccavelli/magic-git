import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/commit_graph.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/list_keyboard_nav.dart';
import '../common/tool_icon_button.dart';
import 'commit_graph_view.dart';
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

  const HistoryView({
    super.key,
    required this.repoPath,
    this.isActive = true,
  });

  @override
  ConsumerState<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends ConsumerState<HistoryView> {
  String? _selectedHash;

  // Guards against opening a second interactive-rebase sheet while one is
  // already up: each sheet captures its own commit-list snapshot, so if the
  // first rebase completes and rewrites hashes before the second is
  // dismissed, the second would operate against stale/nonexistent hashes.
  bool _rebaseSheetOpen = false;

  // Guards against a double-tap (or a mis-click during a confirm dialog's
  // dismiss animation) firing two concurrent commit mutations — cherry-pick and
  // revert run with no confirm dialog, so nothing else serializes them at the
  // UI layer, and a second would run against whatever state the first just
  // produced (e.g. onto a half-applied cherry-pick). Mirrors BranchesView.
  bool _busy = false;

  // History search/filter: a debounced message filter and an all-branches
  // toggle. When either is active the panel uses [logSearchProvider].
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // Keyboard navigation of the commit list: the list takes focus on a row tap,
  // then ↑/↓ walk _selectedHash through the commits, scrolling each into view.
  final FocusNode _commitFocus = FocusNode(debugLabel: 'commit-list');
  final ScrollController _commitScroll = ScrollController();
  final Map<String, GlobalKey> _commitRowKeys = {};

  String _grep = '';
  bool _allBranches = false;
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _commitFocus.dispose();
    _commitScroll.dispose();
    super.dispose();
  }

  GlobalKey _commitRowKeyFor(String hash) =>
      _commitRowKeys.putIfAbsent(hash, GlobalKey.new);

  void _moveCommitSelection(int dir) {
    final commits = _lastCommits;
    if (commits == null || commits.isEmpty) return;
    var current = -1;
    if (_selectedHash != null) {
      for (var i = 0; i < commits.length; i++) {
        if (commits[i].hash == _selectedHash) {
          current = i;
          break;
        }
      }
    }
    final next = stepSelection(current, dir, commits.length);
    setState(() => _selectedHash = commits[next].hash);
    ensureRowVisible(_commitRowKeyFor(commits[next].hash));
  }

  KeyEventResult _onCommitKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || _busy) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveCommitSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveCommitSelection(-1);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The [GitCommit] for [_selectedHash] in the currently-displayed list, or
  /// null if nothing is selected (or the selection scrolled out of a filtered
  /// list). Needed by cherry-pick/rebase, which act on the commit object rather
  /// than a bare hash.
  GitCommit? _selectedCommit() {
    final hash = _selectedHash;
    if (hash == null) return null;
    for (final c in _lastCommits ?? const <GitCommit>[]) {
      if (c.hash == hash) return c;
    }
    return null;
  }

  void _onSearchChanged(String value) {
    // Debounce so a remote `git log` doesn't fire on every keystroke.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _grep = value.trim());
    });
  }

  // Memoized lane graph + ref decorations. Both are recomputed only when their
  // source list *instance* changes (Riverpod hands back the same list across
  // rebuilds until the provider is invalidated), so merely selecting a commit
  // no longer re-lays-out the whole graph or re-groups every ref.
  List<GitCommit>? _lastCommits;
  CommitGraph? _graph;
  List<GitRef>? _lastRefs;
  Map<String, List<GitRef>>? _decorations;

  CommitGraph _graphFor(List<GitCommit> commits) {
    if (!identical(commits, _lastCommits) || _graph == null) {
      _lastCommits = commits;
      _graph = CommitGraph.build(commits);
    }
    return _graph!;
  }

  Map<String, List<GitRef>> _decorationsFor(List<GitRef> refs) {
    if (!identical(refs, _lastRefs) || _decorations == null) {
      _lastRefs = refs;
      _decorations = refsByCommit(refs);
    }
    return _decorations!;
  }

  @override
  void didUpdateWidget(HistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      _selectedHash = null;
      _lastCommits = null;
      _graph = null;
      _lastRefs = null;
      _decorations = null;
    }
  }

  String get repoPath => widget.repoPath;

  void _refresh() {
    // `_run` calls this right after an awaited op with no further check of
    // its own, and touching `ref` after the widget is disposed throws.
    if (!mounted) return;
    ref.invalidate(logProvider(repoPath));
    ref.invalidate(refsProvider(repoPath));
    ref.invalidate(statusProvider(repoPath));
    ref.invalidate(stashesProvider(repoPath));
  }

  /// Runs a mutating op, refreshing on success. [movesHead] clears the diff
  /// selection because the selected commit may no longer exist / be meaningful.
  Future<void> _run(
    Future<void> Function() op, {
    bool movesHead = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await runAction(context, op)) {
        if (movesHead) _selectedHash = null;
        _refresh();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Like [_run], but logs the command's output to the output view — for
  /// operations (cherry-pick, revert) where seeing the actual git output (e.g.
  /// a conflict) matters.
  Future<void> _runLogged(
    String title,
    Future<void> Function(OutputLogNotifier log) body,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    final log = ref.read(outputLogProvider.notifier);
    try {
      await body(log);
    } on GitException catch (e) {
      log.logResult(title, e.result);
      if (mounted) await showErrorDialog(context, e.toString());
    } catch (e) {
      log.logError(title, e.toString());
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      // A conflicting cherry-pick/revert makes GitService throw a
      // GitException — that's the documented way a conflict is signaled, not
      // an exceptional failure — and `pendingOp` is meant to then surface a
      // resolve/abort banner. Refreshing only on success left the History /
      // Repository views showing stale pre-op state with no conflict
      // indication until some unrelated refresh happened to fire, so the
      // refresh has to run here regardless of outcome, mirroring
      // rebase_sheet.dart's `_apply`.
      _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  GitCommit? _commitFor(String hash) {
    for (final c in _lastCommits ?? const <GitCommit>[]) {
      if (c.hash == hash) return c;
    }
    return null;
  }

  // The unfiltered list is `git log HEAD`, so its first row is the current
  // HEAD commit. Under an active filter (grep / all-branches) the displayed
  // list is a subset whose top row need not be HEAD, so refuse to treat any
  // commit as HEAD then: "Amend last commit" rewrites the *real* HEAD, not the
  // shown commit, and must never be offered against a non-HEAD top row.
  bool _isHead(String hash) =>
      _grep.isEmpty &&
      !_allBranches &&
      _lastCommits?.isNotEmpty == true &&
      _lastCommits!.first.hash == hash;

  /// A single-field text prompt (branch name, mainline number). Returns the
  /// trimmed value, or null if cancelled / empty.
  Future<String?> _promptText(
    String title, {
    required String placeholder,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showMacosSheet<String>(
      context: context,
      builder: (sheetContext) => EscapeDismissible(
        child: MacosSheet(
        // A MacosSheet has no intrinsic width — without this it fills the whole
        // window for what is just a title + one text field + Cancel/OK.
        child: SizedBox(
          width: 440,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: MacosTheme.of(sheetContext).typography.title3,
                ),
                const SizedBox(height: 14),
                MacosTextField(
                  controller: controller,
                  placeholder: placeholder,
                  autofocus: true,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  onSubmitted: (v) => Navigator.of(
                    sheetContext,
                  ).pop(v.trim().isEmpty ? null : v),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    PushButton(
                      controlSize: ControlSize.large,
                      onPressed: () => Navigator.of(sheetContext).pop(
                        controller.text.trim().isEmpty ? null : controller.text,
                      ),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
    controller.dispose();
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Resolves the mainline parent for a merge commit: prompts (default 1) when
  /// [commit] is a merge, otherwise returns null (no `-m`).
  Future<int?> _mainlineFor(GitCommit commit) async {
    if (!commit.isMerge) return null;
    final v = await _promptText(
      'Mainline parent',
      placeholder: '1',
      initial: '1',
    );
    if (v == null) return null;
    return int.tryParse(v) ?? 1;
  }

  GitService get _git => ref.read(gitServiceProvider);

  Future<void> _actCheckout(String hash) async {
    final ok = await confirmAction(
      context,
      title: 'Checkout commit',
      message:
          'Check out $hash? You will be on a detached HEAD — create a branch '
          'to keep any new commits.',
      confirmLabel: 'Checkout',
    );
    if (ok) await _run(() => _git.checkout(repoPath, hash), movesHead: true);
  }

  Future<void> _actBranchFrom(String hash) async {
    final name = await _promptText(
      'New branch from commit',
      placeholder: 'branch name',
    );
    if (name != null) {
      await _run(() => _git.branchFrom(repoPath, name, hash), movesHead: true);
    }
  }

  Future<void> _actCherryPick(GitCommit commit) async {
    final label = 'git cherry-pick ${commit.shortHash}';
    if (commit.isMerge) {
      final m = await _mainlineFor(commit);
      if (m == null) return;
      await _runLogged(
        label,
        (log) async => log.logResult(
          label,
          await _git.cherryPick(repoPath, commit.hash, mainline: m),
        ),
      );
    } else {
      await _runLogged(
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
    await _runLogged(
      label,
      (log) async => log.logResult(
        label,
        await _git.revert(repoPath, commit.hash, mainline: m),
      ),
    );
  }

  Future<void> _actReset(String hash, ResetMode mode) async {
    final hard = mode == ResetMode.hard;
    final ok = await confirmAction(
      context,
      title: 'Reset to commit',
      message: hard
          ? 'Hard-reset to $hash? This discards ALL uncommitted changes and '
                'cannot be undone.'
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

  /// Opens the interactive-rebase editor for the commits from [commit] up to
  /// HEAD (rebased onto [commit]'s parent). The sheet performs the rebase and
  /// refreshes the repo-scoped providers itself.
  ///
  /// Always resolves the range from a fresh, *unfiltered* HEAD log — never
  /// from `_lastCommits`, which is whatever the panel is currently displaying
  /// and can be a search/grep- or all-branches-filtered subset. Building the
  /// rebase todo from a filtered list would silently drop every real,
  /// non-matching commit between `onto` and HEAD, since the rebase replaces
  /// history with exactly the `commits` list passed in. If [commit] isn't
  /// actually a HEAD ancestor (reachable only via the all-branches view), it
  /// won't be found in the unfiltered log either — correctly a no-op, since
  /// "rebase from here" isn't meaningful for a non-ancestor commit anyway.
  Future<void> _actRebaseFrom(GitCommit commit) async {
    // Also gated on `_busy` — the same flag cherry-pick/revert/etc. use via
    // `_run`/`_runLogged` — so a rebase can't start while another History
    // mutation is mid-flight, and vice versa: those actions won't fire while
    // this sheet is open, since `_busy` stays set for its whole lifetime.
    if (_busy || _rebaseSheetOpen || commit.parents.isEmpty) return;
    List<GitCommit> commits;
    try {
      commits = await ref.read(logProvider(repoPath).future);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final idx = commits.indexWhere((c) => c.hash == commit.hash);
    if (idx < 0) return;
    // commits[0..idx] are HEAD..selected (newest first); the todo is oldest-first.
    final included = commits.sublist(0, idx + 1).reversed.toList();
    setState(() {
      _rebaseSheetOpen = true;
      _busy = true;
    });
    try {
      await showMacosSheet<void>(
        context: context,
        builder: (_) => EscapeDismissible(
          child: RebaseSheet(
            repoPath: repoPath,
            onto: commit.parents.first,
            commits: included,
          ),
        ),
      );
    } finally {
      _rebaseSheetOpen = false;
      if (mounted) setState(() => _busy = false);
    }
    // A completed rebase rewrites hashes for the whole range — the selected
    // commit (if it was in that range) no longer exists, so the diff pane
    // would otherwise keep requesting a stale hash and surface a raw git
    // error instead of just clearing.
    if (mounted) setState(() => _selectedHash = null);
  }

  @override
  Widget build(BuildContext context) {
    final filtering = _grep.isNotEmpty || _allBranches;
    final logAsync = filtering
        ? ref.watch(
            logSearchProvider((
              repoPath: widget.repoPath,
              grep: _grep.isEmpty ? null : _grep,
              author: null,
              since: null,
              all: _allBranches,
            )),
          )
        : ref.watch(logProvider(widget.repoPath));
    // Ref decorations are best-effort: if for-each-ref fails, show a bare graph.
    final decorations = _decorationsFor(
      ref.watch(refsProvider(widget.repoPath)).value ?? const [],
    );

    final keymap = ref.watch(keymapProvider);
    final selectedHash = _selectedHash;
    final selectedCommit = _selectedCommit();
    final hasCommits = _lastCommits?.isNotEmpty ?? false;

    return CallbackShortcuts(
      bindings: widget.isActive && !_busy
          ? resolveShortcuts(keymap, {
              'history.copySha': selectedHash == null
                  ? null
                  : () => _copySha(selectedHash),
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
            })
          : const <ShortcutActivator, VoidCallback>{},
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _filterBar(context, filtering),
              Container(height: 1, color: MacosColors.separatorColor),
              Expanded(
                child: logAsync.when(
                  loading: () => const Center(child: ProgressCircle()),
                  error: (err, _) => _error(context, err),
                  data: (commits) => commits.isEmpty
                      ? Center(
                          child: Text(
                            filtering ? 'No matching commits' : 'No commits',
                            style: MacosTheme.of(context).typography.body
                                .copyWith(color: MacosColors.systemGrayColor),
                          ),
                        )
                      : _commitList(context, _graphFor(commits), decorations),
                ),
              ),
            ],
          ),
        ),
        Container(width: 1, color: MacosColors.separatorColor),
        Expanded(
          child: _selectedHash == null
              ? Center(
                  child: Text(
                    'Select a commit',
                    style: MacosTheme.of(context).typography.body,
                  ),
                )
              : _commitDiff(context, _selectedHash!),
        ),
      ],
      ),
    );
  }

  Widget _filterBar(BuildContext context, bool filtering) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: MacosTextField(
              controller: _searchController,
              focusNode: _searchFocus,
              placeholder: 'Filter commits by message…',
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
              onChanged: _onSearchChanged,
            ),
          ),
          const SizedBox(width: 6),
          ToolIconButton(
            icon: _allBranches
                ? CupertinoIcons.square_stack_3d_up_fill
                : CupertinoIcons.square_stack_3d_up,
            tooltip: _allBranches
                ? 'Showing all branches'
                : 'Show all branches',
            size: 16,
            color: _allBranches ? MacosColors.systemBlueColor : null,
            onPressed: () => setState(() => _allBranches = !_allBranches),
          ),
        ],
      ),
    );
  }

  Widget _commitList(
    BuildContext context,
    CommitGraph graph,
    Map<String, List<GitRef>> decorations,
  ) {
    final typography = MacosTheme.of(context).typography;
    // Clamp the drawn lane *band* so a very wide graph can't crowd out the
    // text — but a topology with more than [_maxFullWidthLanes] concurrent
    // lanes (e.g. many long-lived branches active at once) must still have
    // every lane rendered somewhere in that band, just thinner, rather than
    // having the overflow lanes clipped away to invisible (silently dropping
    // a commit's line). `laneWidth` is what's actually fed to the painter;
    // it only shrinks below [kLaneWidth] once the lane count exceeds the cap.
    const maxFullWidthLanes = 8;
    final laneCount = graph.laneCount < 1 ? 1 : graph.laneCount;
    final visibleLaneCount = laneCount.clamp(1, maxFullWidthLanes);
    final graphWidth = visibleLaneCount * kLaneWidth + kLaneWidth / 2;
    final laneWidth = laneCount > maxFullWidthLanes
        ? graphWidth / (laneCount + 0.5)
        : kLaneWidth;

    return Focus(
      focusNode: _commitFocus,
      onKeyEvent: _onCommitKey,
      child: ListView.builder(
      controller: _commitScroll,
      itemCount: graph.rows.length,
      itemBuilder: (context, index) {
        final row = graph.rows[index];
        final commit = row.commit;
        final selected = commit.hash == _selectedHash;
        return GestureDetector(
          key: _commitRowKeyFor(commit.hash),
          onTap: () {
            _commitFocus.requestFocus();
            setState(() => _selectedHash = commit.hash);
          },
          child: Container(
            color: selected
                ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
                : const Color(0x00000000),
            height: kGraphRowHeight,
            child: Row(
              children: [
                // Clip to the fixed band so rounding in the compressed-lane
                // math can never paint a hair over the ref chips, subject, or
                // author text to the right — every lane itself is still drawn
                // (compressed via `laneWidth` above once the count exceeds
                // the cap), never dropped.
                ClipRect(
                  child: CustomPaint(
                    size: Size(graphWidth, kGraphRowHeight),
                    painter: CommitRowPainter(row, laneWidth: laneWidth),
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
                            const MacosIcon(
                              CupertinoIcons.arrow_merge,
                              size: 13,
                            ),
                            const SizedBox(width: 4),
                          ],
                          for (final r
                              in decorations[commit.hash] ?? const <GitRef>[])
                            RefChip(gitRef: r),
                          Expanded(
                            child: Text(
                              commit.subject,
                              style: typography.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
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
        );
      },
      ),
    );
  }

  Widget _commitDiff(BuildContext context, String hash) {
    final diffAsync = ref.watch(commitDiffProvider((widget.repoPath, hash)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _diffHeader(context, hash),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => _error(context, err),
            data: (diff) => DiffView(diff: diff),
          ),
        ),
      ],
    );
  }

  /// Slim bar atop the diff pane: the short hash on the left, then commit
  /// actions (copy SHA, an actions menu) and a pop-out button on the right.
  Widget _diffHeader(BuildContext context, String hash) {
    final typography = MacosTheme.of(context).typography;
    final short = hash.length > 10 ? hash.substring(0, 10) : hash;
    final commit = _commitFor(hash);
    final isHead = _isHead(hash);
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
          if (commit != null) _actionsMenu(commit, isHead),
        ],
      ),
    );
  }

  Widget _actionsMenu(GitCommit commit, bool isHead) {
    final hash = commit.hash;
    // Every item below mutates the repo, so each is disabled — both visually
    // (greyed via `enabled: false`, matching the built-in disabled style
    // MacosPulldownMenuItem already applies for the "Reset to…" header) and
    // functionally (`onTap: null`, mirroring the `onPressed: _busy ? null :
    // …` idiom used by RepoStatusView/StashView) — while an operation is
    // already mid-flight, so a second tap can't queue up behind it.
    final canAct = !_busy;
    final canRebase = canAct && commit.parents.isNotEmpty;
    return MacosPulldownButtonTheme(
      data: MacosPulldownButtonTheme.of(
        context,
      ).copyWith(iconColor: MacosColors.systemGrayColor),
      child: MacosPulldownButton(
        // Convention: toolbar menus use the "hamburger" (three horizontal
        // lines) glyph — the universally recognized menu affordance.
        icon: CupertinoIcons.line_horizontal_3,
        items: [
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('Checkout'),
            onTap: canAct ? () => _actCheckout(hash) : null,
          ),
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('Branch from here…'),
            onTap: canAct ? () => _actBranchFrom(hash) : null,
          ),
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('Cherry-pick'),
            onTap: canAct ? () => _actCherryPick(commit) : null,
          ),
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('Revert'),
            onTap: canAct ? () => _actRevert(commit) : null,
          ),
          MacosPulldownMenuItem(
            enabled: canRebase,
            title: const Text('Interactive rebase from here…'),
            onTap: canRebase ? () => _actRebaseFrom(commit) : null,
          ),
          const MacosPulldownMenuItem(enabled: false, title: Text('Reset to…')),
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('  Soft (keep changes staged)'),
            onTap: canAct ? () => _actReset(hash, ResetMode.soft) : null,
          ),
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('  Mixed (keep changes unstaged)'),
            onTap: canAct ? () => _actReset(hash, ResetMode.mixed) : null,
          ),
          MacosPulldownMenuItem(
            enabled: canAct,
            title: const Text('  Hard (discard changes)'),
            onTap: canAct ? () => _actReset(hash, ResetMode.hard) : null,
          ),
          if (isHead)
            MacosPulldownMenuItem(
              enabled: canAct,
              title: const Text('Amend last commit'),
              onTap: canAct ? _actAmend : null,
            ),
        ],
      ),
    );
  }

  Widget _error(BuildContext context, Object err) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        '$err',
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
    final diffAsync = ref.watch(commitDiffProvider((repoPath, hash)));
    final short = hash.length > 12 ? hash.substring(0, 12) : hash;
    final screen = MediaQuery.of(context).size;

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
                data: (diff) => DiffView(diff: diff),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
