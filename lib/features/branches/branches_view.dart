import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/branch_switch.dart';
import '../common/field_styles.dart';
import '../common/list_keyboard_nav.dart';
import '../common/tool_icon_button.dart';

/// Source-control pane: local branches (checkout/delete/create), remote-tracking
/// branches, and tags. Stashes have their own top-level namespace (StashView).
class BranchesView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether this panel is the currently-visible sidebar page. It stays
  /// mounted when another page is shown, so its keyboard shortcuts must go
  /// quiet rather than fire in the background.
  final bool isActive;

  const BranchesView({
    super.key,
    required this.repoPath,
    this.isActive = true,
  });

  @override
  ConsumerState<BranchesView> createState() => _BranchesViewState();
}

class _BranchesViewState extends ConsumerState<BranchesView> {
  final _newBranch = TextEditingController();
  final _newBranchFocus = FocusNode();
  final _newTag = TextEditingController();
  final _newTagFocus = FocusNode();

  // Guards against a double-tap (or a mis-click during a confirm dialog's
  // dismiss animation) firing two concurrent mutations against the same repo
  // — the SSH executor serializes the commands themselves, but a second one
  // would then run against whatever state the first just changed, out from
  // under the user (e.g. checking out a different branch mid-delete).
  bool _busy = false;

  // Keyboard navigation of the local-branch list: a click selects a branch
  // (highlight) and focuses the list; ↑/↓ then walk the selection, Enter checks
  // it out, and ⌘⇧M / ⌘⌫ merge / delete it. Checkout also has its own row
  // button so the mouse-only path doesn't depend on the keyboard.
  String? _selectedBranch;
  List<GitRef> _locals = const [];
  final FocusNode _branchFocus = FocusNode(debugLabel: 'branch-list');
  final ScrollController _branchScroll = ScrollController();
  final Map<String, GlobalKey> _branchRowKeys = {};

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _newBranch.dispose();
    _newBranchFocus.dispose();
    _newTag.dispose();
    _newTagFocus.dispose();
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
    if (event is KeyUpEvent || !widget.isActive || _busy) {
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
    }
    return KeyEventResult.ignored;
  }

  void _refresh() {
    ref.invalidate(refsProvider(repoPath));
    ref.invalidate(statusProvider(repoPath));
    ref.invalidate(logProvider(repoPath));
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runAction(context, op);
    } finally {
      // Refresh even when `op` failed: e.g. a rejected delete/create can
      // still be a GitException that signals a conflict-like state (and, for
      // any op, refsProvider/statusProvider are the source of truth this
      // view renders from — leaving them stale on failure is exactly the bug
      // this `finally` closes). Guarded together with the busy reset since
      // both touch `ref`/state that's unsafe after disposal.
      if (mounted) {
        _refresh();
        setState(() => _busy = false);
      }
    }
  }

  /// Like [_run], but logs the command's output to the output view — for
  /// operations (merge) where seeing the actual git output (e.g. a conflict)
  /// matters.
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
      // Refresh regardless of outcome: a merge conflict is signaled by
      // GitService throwing a GitException (not a special return value), and
      // refsProvider/statusProvider — and thus pendingOpProvider — need to
      // pick up the resulting merge-in-progress state so the Repository
      // panel's conflict banner appears right away instead of after some
      // unrelated later refresh.
      if (mounted) {
        _refresh();
        setState(() => _busy = false);
      }
    }
  }

  /// Checks out [ref] behind the dirty-tree guardrail (stash / carry / cancel),
  /// refreshing regardless of outcome (see the `finally` block).
  Future<void> _checkout(GitService git, String ref) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await guardedBranchSwitch(
        context,
        this.ref,
        repoPath,
        () => git.checkout(repoPath, ref),
      );
    } finally {
      // Refresh even on a failed/cancelled switch: guardedBranchSwitch's
      // stash step can succeed while the checkout itself then fails, leaving
      // partial state (stash created, branch unchanged) that refsProvider/
      // statusProvider need to reflect rather than staying stale.
      if (mounted) {
        _refresh();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final refsAsync = ref.watch(refsProvider(repoPath));
    final git = ref.read(gitServiceProvider);
    final keymap = ref.watch(keymapProvider);

    return CallbackShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, {
              'branches.newBranch': () => _newBranchFocus.requestFocus(),
              'branches.createTag': () => _newTagFocus.requestFocus(),
              // Only bound with a non-current branch selected — otherwise they
              // fall through, matching the rest of the app's precondition gates.
              'branches.merge': _canActOnSelection
                  ? () => _mergeBranch(git, _selectedBranch!, MergeMode.normal)
                  : null,
              'branches.delete': _canActOnSelection
                  ? () => _deleteBranch(git, _selectedBranch!)
                  : null,
            })
          : const <ShortcutActivator, VoidCallback>{},
      child: refsAsync.when(
        loading: () => const Center(child: ProgressCircle()),
        error: (err, _) => _error(context, err),
        data: (refs) {
          final locals = refs.where((r) => r.isLocalBranch).toList();
          final remotes = refs.where((r) => r.isRemote).toList();
          final tags = refs.where((r) => r.isTag).toList();
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
            _HeaderRow('Tags (${tags.length})'),
            const _CreateTagRow(),
            for (final t in tags) _TagRefRow(t),
          ];
          return Focus(
            focusNode: _branchFocus,
            onKeyEvent: _onBranchKey,
            child: ListView.builder(
              controller: _branchScroll,
              itemCount: rows.length,
              itemBuilder: (context, i) => switch (rows[i]) {
                _CreateBranchRow() => _createBranchBar(git),
                _CreateTagRow() => _createTagBar(git),
                _HeaderRow(:final title) => _sectionHeader(context, title),
                _BranchRow(:final branch, :final remote) => remote
                    ? _remoteRow(context, git, branch)
                    : _localRow(context, git, branch),
                _TagRefRow(:final tag) => _tagRow(context, git, tag),
              },
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
            builder: (context, value, _) => PushButton(
              controlSize: ControlSize.large,
              onPressed: value.text.trim().isEmpty || _busy
                  ? null
                  : () async {
                      final name = value.text.trim();
                      await _run(() => git.createBranch(repoPath, name));
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
    // A single click selects (so ↑/↓, Enter, ⌘⇧M and ⌘⌫ target it); checkout is
    // its own button (below) and Enter, so selecting can't accidentally switch
    // branches. The current branch keeps its green tint.
    return KeyedSubtree(
      key: _branchRowKeyFor(branch.shortName),
      child: GestureDetector(
      onTap: () => _selectBranch(branch.shortName),
      child: Container(
        color: branch.isHead
            ? MacosColors.systemGreenColor.withValues(alpha: 0.12)
            : selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
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
            if (branch.upstream != null)
              Text(
                branch.upstream!,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            if (!branch.isHead) ...[
              const SizedBox(width: 4),
              ToolIconButton(
                icon: CupertinoIcons.square_arrow_down,
                tooltip: 'Checkout branch',
                size: 15,
                onPressed: _busy ? null : () => _checkout(git, branch.shortName),
              ),
              const SizedBox(width: 4),
              MacosPulldownButton(
                icon: CupertinoIcons.arrow_merge,
                items: [
                  MacosPulldownMenuItem(
                    title: const Text('Merge into current'),
                    onTap: () =>
                        _mergeBranch(git, branch.shortName, MergeMode.normal),
                  ),
                  MacosPulldownMenuItem(
                    title: const Text('Merge (no fast-forward)'),
                    onTap: () =>
                        _mergeBranch(git, branch.shortName, MergeMode.noFf),
                  ),
                  MacosPulldownMenuItem(
                    title: const Text('Squash merge'),
                    onTap: () =>
                        _mergeBranch(git, branch.shortName, MergeMode.squash),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              ToolIconButton(
                icon: CupertinoIcons.trash,
                tooltip: 'Delete branch',
                size: 14,
                color: MacosColors.systemRedColor,
                onPressed: _busy
                    ? null
                    : () => _deleteBranch(git, branch.shortName),
              ),
            ],
          ],
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
    if (_busy) return;
    final ok = await confirmAction(
      context,
      title: 'Delete branch',
      message: 'Delete local branch "$name"?',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await git.deleteBranch(repoPath, name);
    } on GitException catch (e) {
      if (!mounted) return;
      if (!e.result.stderr.contains('not fully merged')) {
        await showErrorDialog(context, e.toString());
        return;
      }
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
      // Uses runAction directly (not _run) — _busy is already held by this
      // call, and _run would just no-op seeing it set. Its own refresh is
      // covered by this method's shared `finally` below.
      if (force && mounted) {
        await runAction(
          context,
          () => git.deleteBranch(repoPath, name, force: true),
        );
      }
    } catch (e) {
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      // Refresh regardless of outcome — including the "not fully merged"
      // rejection and a declined/failed force-delete — so refsProvider picks
      // up whatever state (or lack of change) the attempt actually left,
      // rather than showing the stale pre-delete branch list until an
      // unrelated refresh happens later.
      if (mounted) {
        _refresh();
        setState(() => _busy = false);
      }
    }
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
    await _runLogged(
      label,
      (log) async =>
          log.logResult(label, await git.merge(repoPath, branch, mode: mode)),
    );
  }

  Widget _createTagBar(GitService git) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: MacosTextField(
              controller: _newTag,
              focusNode: _newTagFocus,
              placeholder: 'New tag at HEAD',
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
            ),
          ),
          const SizedBox(width: 8),
          // See _createBranchBar — listens to the controller directly rather
          // than `setState`-ing the whole view on every keystroke.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _newTag,
            builder: (context, value, _) => PushButton(
              controlSize: ControlSize.large,
              onPressed: value.text.trim().isEmpty || _busy
                  ? null
                  : () async {
                      final name = value.text.trim();
                      await _run(() => git.createTag(repoPath, name));
                      // See _createBranchBar — guard against a dispose during
                      // the await before touching the controller.
                      if (mounted) _newTag.clear();
                    },
              child: const Text('Tag'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagRow(BuildContext context, GitService git, GitRef tag) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.tag,
            size: 15,
            color: MacosColors.systemTealColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tag.shortName,
              style: typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ToolIconButton(
            icon: CupertinoIcons.cloud_upload,
            tooltip: 'Push tag to origin',
            size: 15,
            onPressed: _busy
                ? null
                : () => _run(() => git.pushTag(repoPath, tag.shortName)),
          ),
          ToolIconButton(
            icon: CupertinoIcons.trash,
            tooltip: 'Delete tag',
            size: 14,
            color: MacosColors.systemRedColor,
            onPressed: _busy
                ? null
                : () async {
                    final ok = await confirmAction(
                      context,
                      title: 'Delete tag',
                      message: 'Delete local tag "${tag.shortName}"?',
                      confirmLabel: 'Delete',
                    );
                    if (ok) {
                      await _run(() => git.deleteTag(repoPath, tag.shortName));
                    }
                  },
          ),
        ],
      ),
    );
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
            onPressed: _busy ? null : () => _checkout(git, localName),
          ),
        ],
      ),
    );
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
