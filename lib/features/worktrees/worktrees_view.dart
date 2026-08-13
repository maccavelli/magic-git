import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/providers/window_manager_bridge.dart';
import '../../core/utils/display_error.dart';
import '../branches/branches_view.dart';
import '../common/actions.dart';
import '../common/async_views.dart';
import '../common/busy_action.dart';
import '../common/buttons.dart';
import '../common/context_menu.dart';
import '../common/label_chip.dart';
import '../common/prompt_text_sheet.dart';
import '../common/repository_context.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../history/history_view.dart';
import '../repository/repo_status_view.dart';
import '../stash/stash_view.dart';
import 'add_worktree_sheet.dart';
import 'worktree_access.dart';
import 'worktree_paths.dart';
import 'worktree_tabs.dart';

/// The **Worktrees** namespace — a dedicated home for `git worktree`.
///
/// ## Why worktrees get their own space
///
/// A worktree is a second (third, tenth) checkout of the same repository, so you
/// can build a hotfix while a feature is half-finished, review a PR without
/// stashing, or run several agents in parallel. Power users keep 20–30 of them.
///
/// They are deliberately NOT put in the app's global tab strip — that is the
/// *repository* switcher, it caps at 8, and filling it with near-identical
/// entries from one repo is the exact complaint filed against Fork and GitHub
/// Desktop. Instead they live here, and the main repository stays clean.
///
/// ## Layout
///
/// A horizontal tab strip (NOT a second left rail — the main sidebar already
/// costs 240px, and a second vertical list would leave too little room for
/// content on a laptop screen):
///
///   [ Overview | feature-auth ✕ | hotfix ✕ ]            [+] [⟳] [☰]
///
/// **Overview** is the management table: every worktree, its branch, and its
/// state (main / detached / locked / missing), with row actions.
///
/// A **worktree tab** is a full workspace for that checkout — Changes, History,
/// Branches and Stashes, which are the very same panels the main repo uses,
/// handed `repoPath: <the worktree>`. They need no changes: every panel is
/// already a pure function of its repoPath, and every provider is a family keyed
/// on it, so the data isolates itself.
///
/// Forge and Project are deliberately absent: they describe the *repository*
/// (its remote, its PRs), not a checkout of it, so duplicating them per worktree
/// would be noise.
class WorktreesView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether this is the visible panel. Composed with "is this worktree tab
  /// frontmost" before being handed down, so a background worktree's panel
  /// doesn't install its keyboard shortcuts.
  final bool isActive;

  const WorktreesView({
    super.key,
    required this.repoPath,
    this.isActive = true,
  });

  @override
  ConsumerState<WorktreesView> createState() => _WorktreesViewState();
}

/// The sub-panels a worktree tab offers.
///
/// Forge and Project are deliberately absent — they describe the *repository*
/// (its remote, its pull requests), not a checkout of it, so a copy per worktree
/// would be pure noise. Four also fits a row of chips, which keeps the nested
/// navigation from needing a second sidebar.
const List<(String, IconData)> _subPanels = [
  ('Changes', CupertinoIcons.folder),
  ('History', CupertinoIcons.clock),
  ('Branches', CupertinoIcons.arrow_branch),
  ('Stashes', CupertinoIcons.tray_2),
];

class _WorktreesViewState extends ConsumerState<WorktreesView>
    with BusyActionState {
  final ContextMenuOverlay _contextMenu = ContextMenuOverlay();

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _contextMenu.dispose();
    super.dispose();
  }

  /// Every worktree mutation refreshes through the ONE shared helper — a
  /// worktree added or removed here changes `<common>/.git/worktrees/`, which
  /// every other worktree of this repo reads. See [refreshAfterMutation].
  void _refresh() => refreshAfterMutation(ref, repoPath);

  @override
  void refreshAfterAction() => _refresh();

  // ---------------------------------------------------------------- actions

  Future<void> _openWorktree(GitWorktree wt) async {
    if (wt.isPrunable) {
      await showErrorDialog(
        context,
        "This worktree's folder is missing — git still has a record of it but "
        'the directory is gone.\n\nUse Prune to forget it, or Repair if you '
        'moved it somewhere else.',
      );
      return;
    }
    // The main worktree IS the repo this tab is already showing — opening it as
    // a nested workspace would be a confusing duplicate of the panels next door.
    if (wt.isMain) {
      await showErrorDialog(
        context,
        'This is the main worktree — it is the repository you already have '
        'open. Use the Repository, History and Branches panels for it.',
      );
      return;
    }
    // Sandbox: a worktree lives outside the main repo's grant, so working in one
    // needs a grant of its own. Prompts once, then never again.
    final ok = await ref.read(worktreeAccessProvider).ensure(context, wt.path);
    if (!ok || !mounted) return;
    ref.read(worktreeTabsProvider.notifier).open(wt.path);
  }

  Future<void> _closeTab(String path) async {
    ref.read(worktreeTabsProvider.notifier).close(path);
    await ref.read(worktreeAccessProvider).release(path);
  }

  Future<void> _remove(GitWorktree wt, {required bool alsoDeleteBranch}) async {
    final branch = wt.branch?.replaceFirst('refs/heads/', '');
    // A detached worktree has no branch — the delete-branch variant is
    // disabled for it, but plain removal is not, and its message must not
    // interpolate a null into `The branch "null" is kept`.
    final keptNote = branch == null
        ? 'This worktree has a detached HEAD — no branch is affected.'
        : 'The branch "$branch" is kept — you can check it out again later.';
    final ok = await confirmAction(
      context,
      title: alsoDeleteBranch
          ? 'Remove worktree and delete branch?'
          : 'Remove worktree?',
      message: alsoDeleteBranch
          ? 'This deletes the folder\n${wt.path}\nand then deletes the branch '
                '"$branch".\n\nCommits on the branch will only be reachable '
                'through the reflog.'
          : 'This deletes the folder\n${wt.path}\n\n$keptNote',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;

    await runGuarded(() async {
      final git = ref.read(gitServiceProvider);
      try {
        await git.removeWorktree(repoPath, wt.path, locked: wt.isLocked);
      } on GitException catch (e) {
        // git refuses to remove a worktree with uncommitted or untracked files
        // (and, separately, a locked one). Rather than dead-ending on git's raw
        // message, name the situation and offer the override it is asking for.
        final dirty = e.worktreeDirty;
        final locked = e.worktreeLocked;
        if (!dirty && !locked) rethrow;
        if (!mounted) rethrow;
        final force = await confirmAction(
          context,
          title: dirty
              ? 'Worktree has uncommitted changes'
              : 'Worktree is locked',
          message: dirty
              ? 'This worktree has modified or untracked files. Removing it '
                    'deletes them permanently.'
              : 'This worktree is locked${wt.lockReason?.isNotEmpty ?? false ? ' (${wt.lockReason})' : ''}. '
                    'Locking normally means it lives on a drive that is not '
                    'always mounted.',
          confirmLabel: 'Remove Anyway',
          destructive: true,
        );
        if (!force) return;
        await git.removeWorktree(
          repoPath,
          wt.path,
          force: true,
          locked: wt.isLocked,
        );
      }
      if (alsoDeleteBranch && branch != null) {
        // Only possible AFTER the worktree is gone: git flatly refuses to delete
        // a branch that is checked out somewhere, and there is no override for
        // it (`--ignore-other-worktrees` exists on checkout/switch, not branch).
        await git.deleteBranch(repoPath, branch, force: true);
      }
      // forget, not release: the folder is gone, so its saved-grant entry
      // must go too or it lingers as a dead Connections-panel row.
      await ref.read(worktreeAccessProvider).forget(wt.path);
      ref.read(worktreeTabsProvider.notifier).close(wt.path);
      // The worktree acted as its own repoPath for its panels — drop its
      // edit stamps and any detached window still pinned to the dead folder.
      ref.read(worktreeEditsProvider.notifier).forgetRepo(wt.path);
      await WindowManagerBridge.current?.closeDetachedRepoWindows(wt.path);
    });
  }

  Future<void> _prune() async {
    final git = ref.read(gitServiceProvider);
    List<String> preview;
    try {
      preview = await git.pruneWorktrees(repoPath, dryRun: true);
    } catch (e) {
      if (mounted) await showErrorDialog(context, displayError(e));
      return;
    }
    if (!mounted) return;
    if (preview.isEmpty) {
      await showErrorDialog(context, 'Nothing to prune — no stale worktrees.');
      return;
    }
    // Show what will actually happen before doing it. `prune` is not
    // destructive (it never deletes a working tree, only git's record of one),
    // but it is confusing if it silently forgets something you meant to repair.
    final ok = await confirmAction(
      context,
      title: 'Prune stale worktrees?',
      message:
          'git will forget these records. No files are deleted — the folders '
          'are already gone.\n\n${preview.join('\n')}',
      confirmLabel: 'Prune',
    );
    if (!ok || !mounted) return;
    await runGuarded(() => git.pruneWorktrees(repoPath));
  }

  /// Re-links a worktree whose folder was moved behind git's back (dragged in
  /// Finder), leaving the admin entry pointing at the old location.
  ///
  /// git must be told where the folder is NOW: `git worktree repair` takes the
  /// new path as an operand. Without one it only re-checks the paths already on
  /// record — verified against git 2.55: it exits 0 having fixed nothing, which
  /// is exactly the moved-folder case this button exists for. On macOS the
  /// folder picker doubles as the sandbox grant git needs to read the moved
  /// folder's `.git` file.
  Future<void> _repair(GitWorktree wt) async {
    final isLocal = ref.read(connectionProvider).isLocal;
    final String? newPath;
    if (isLocal) {
      newPath = await getDirectoryPath(
        confirmButtonText: 'Repair',
        initialDirectory: _parentOf(wt.path),
      );
    } else {
      newPath = await _promptPath(
        title: 'Repair worktree',
        message: 'Where is "${wt.name}" now?',
        initial: wt.path,
        confirmLabel: 'Repair',
      );
    }
    if (newPath == null || !mounted) return;
    final path = newPath;
    await runGuarded(
      () => ref.read(gitServiceProvider).repairWorktrees(repoPath, [path]),
    );
  }

  /// Relocates a worktree with `git worktree move`, which rewrites BOTH halves
  /// of the two-way link (the worktree's `.git` file, and the `gitdir` file in
  /// the main repo's admin directory).
  ///
  /// This is why it exists as an action rather than leaving the user to drag the
  /// folder in Finder: moving it behind git's back breaks the link, and the
  /// worktree then shows up here as "missing" needing a Repair.
  Future<void> _move(GitWorktree wt) async {
    final isLocal = ref.read(connectionProvider).isLocal;
    String? destination;

    if (isLocal) {
      // The sandbox again: git has to CREATE the directory at the new location,
      // so we need a grant on the folder it goes into. The picker IS the grant.
      final parent = await getDirectoryPath(
        confirmButtonText: 'Move Here',
        initialDirectory: _parentOf(wt.path),
      );
      if (parent == null || !mounted) return;
      destination = '$parent/${wt.name}';
    } else {
      destination = await _promptPath(
        title: 'Move worktree',
        message: 'New location for "${wt.name}".',
        initial: wt.path,
      );
      if (destination == null || !mounted) return;
    }

    if (destination == wt.path) return;
    // A worktree inside the repository shows up as untracked noise in the
    // repository's own status — the same rule the Add sheet enforces,
    // symlink-insensitively (a /tmp alias of the repo must not slip past).
    if (isInsideRepo(destination, repoPath)) {
      await showErrorDialog(
        context,
        'Move it outside the repository — a worktree inside it would show up '
        "as untracked files in the repository's own status.",
      );
      return;
    }

    final from = wt.path;
    final to = destination;
    await runGuarded(() async {
      final git = ref.read(gitServiceProvider);
      try {
        await git.moveWorktree(repoPath, from, to);
      } on GitException catch (e) {
        // git refuses to move a LOCKED worktree (it may live on a volume that
        // isn't mounted). Say so, rather than handing over the raw message.
        if (!e.worktreeLocked) rethrow;
        if (!mounted) rethrow;
        await showErrorDialog(
          context,
          'This worktree is locked${wt.lockReason?.isNotEmpty ?? false ? ' (${wt.lockReason})' : ''} '
          'and cannot be moved. Unlock it first.',
        );
        return;
      }
      // The tab (and its sandbox grant) pointed at the OLD path, which no longer
      // exists — reopen it at the new one rather than leaving a dead tab behind.
      // forget, not release: the old path's saved-grant entry is dead too, as
      // are its edit stamps and any detached window pinned to it.
      final wasOpen = ref.read(worktreeTabsProvider).open.contains(from);
      await ref.read(worktreeAccessProvider).forget(from);
      ref.read(worktreeTabsProvider.notifier).close(from);
      ref.read(worktreeEditsProvider.notifier).forgetRepo(from);
      await WindowManagerBridge.current?.closeDetachedRepoWindows(from);
      if (wasOpen && mounted) {
        final ok = await ref.read(worktreeAccessProvider).ensure(context, to);
        if (ok) ref.read(worktreeTabsProvider.notifier).open(to);
      }
    });
  }

  static String _parentOf(String path) {
    final parts = path.split('/')..removeLast();
    return parts.join('/');
  }

  /// A plain path prompt, for the SSH backend where there is no folder
  /// picker. Delegates to the shared [promptText] — the hand-rolled dialog
  /// this replaced disposed its controller the moment the dialog popped,
  /// while the dismiss animation was still rebuilding the field against it
  /// (the exact bug promptText was extracted to eliminate).
  Future<String?> _promptPath({
    required String title,
    required String message,
    required String initial,
    String confirmLabel = 'Move',
  }) => promptText(
    context,
    title,
    placeholder: initial,
    initial: initial,
    description: message,
    confirmLabel: confirmLabel,
  );

  Future<void> _toggleLock(GitWorktree wt) async {
    final git = ref.read(gitServiceProvider);
    if (wt.isLocked) {
      await runGuarded(() => git.unlockWorktree(repoPath, wt.path));
      return;
    }
    await runGuarded(() => git.lockWorktree(repoPath, wt.path));
  }

  Future<void> _add() async {
    await showMacosSheet<void>(
      context: context,
      builder: (_) => AddWorktreeSheet(repoPath: repoPath),
    );
    _refresh();
  }

  /// Opens the worktree as a full detached window — the escape hatch for one you
  /// intend to live in, or to see two side by side. [openDetachedRepo] already
  /// pins a window to an arbitrary repo path, so this is nearly free.
  Future<void> _openInWindow(GitWorktree wt) async {
    final ok = await ref.read(worktreeAccessProvider).ensure(context, wt.path);
    if (!ok) return;
    await WindowManagerBridge.current?.openDetachedRepo(wt.path);
  }

  Future<void> _revealInFinder(String path) async {
    try {
      await Process.run('open', ['-R', path]);
    } catch (e) {
      if (mounted) await showErrorDialog(context, 'Could not open Finder: $e');
    }
  }

  Future<void> _openInTerminal(String path) async {
    try {
      await Process.run('open', ['-a', 'Terminal', path]);
    } catch (e) {
      if (mounted) {
        await showErrorDialog(context, 'Could not open Terminal: $e');
      }
    }
  }

  // ------------------------------------------------------------------- menu

  List<ContextMenuEntry> _rowMenu(GitWorktree wt) {
    final isLocal = ref.read(connectionProvider).isLocal;
    final branch = wt.branch?.replaceFirst('refs/heads/', '');
    return [
      if (!wt.isMain && !wt.isPrunable)
        ContextMenuItem(
          icon: CupertinoIcons.square_arrow_right,
          label: 'Open Worktree',
          onTap: () => _openWorktree(wt),
        ),
      if (!wt.isMain && !wt.isPrunable)
        ContextMenuItem(
          icon: CupertinoIcons.macwindow,
          label: 'Open in Window',
          onTap: () => _openInWindow(wt),
        ),
      if (wt.isPrunable)
        ContextMenuItem(
          icon: CupertinoIcons.wrench,
          label: 'Repair…',
          onTap: () => _repair(wt),
        ),
      const ContextMenuDivider(),
      // Finder and Terminal are meaningless for a repo on a remote host.
      if (isLocal)
        ContextMenuItem(
          icon: CupertinoIcons.folder,
          label: 'Reveal in Finder',
          enabled: !wt.isPrunable,
          onTap: () => _revealInFinder(wt.path),
        ),
      if (isLocal)
        ContextMenuItem(
          icon: CupertinoIcons.chevron_left_slash_chevron_right,
          label: 'Open in Terminal',
          enabled: !wt.isPrunable,
          onTap: () => _openInTerminal(wt.path),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_clipboard,
        label: 'Copy Path',
        onTap: () => Clipboard.setData(ClipboardData(text: wt.path)),
      ),
      if (!wt.isMain) ...[
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: wt.isLocked ? CupertinoIcons.lock_open : CupertinoIcons.lock,
          label: wt.isLocked ? 'Unlock' : 'Lock',
          onTap: () => _toggleLock(wt),
        ),
        // `git worktree move` rewrites both halves of the two-way link. Dragging
        // the folder in Finder instead breaks it, and the worktree then turns up
        // here as "missing" needing a Repair — so this is the safe way to do it.
        ContextMenuItem(
          icon: CupertinoIcons.arrow_right_arrow_left,
          label: 'Move…',
          // Nothing to move: the directory is already gone. Repair is the fix.
          enabled: !wt.isPrunable && !wt.isLocked,
          disabledTooltip: wt.isPrunable
              ? "This worktree's folder is missing — use Repair or Prune"
              : 'A locked worktree cannot be moved — unlock it first',
          onTap: () => _move(wt),
        ),
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: CupertinoIcons.trash,
          label: 'Remove Worktree…',
          iconColor: MacosColors.systemRedColor,
          onTap: () => _remove(wt, alsoDeleteBranch: false),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.trash_fill,
          label: 'Remove Worktree and Delete Branch…',
          // A detached worktree has no branch to delete.
          enabled: branch != null,
          disabledTooltip: branch == null
              ? 'This worktree has a detached HEAD — there is no branch'
              : null,
          iconColor: MacosColors.systemRedColor,
          onTap: () => _remove(wt, alsoDeleteBranch: true),
        ),
      ],
    ];
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final worktreesAsync = ref.watch(gitWorktreesProvider(repoPath));
    final tabs = ref.watch(worktreeTabsProvider);

    // A worktree removed here, or pruned in a terminal, must not leave a tab
    // pointing at a dead path where every git call would fail.
    final live = worktreesAsync.value;
    if (live != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final connection = ref.read(connectionProvider);
        if (connection.sessionEpoch <= 0) return;
        final selected = tabs.selected;
        final label = selected == null
            ? '${live.length} worktree${live.length == 1 ? '' : 's'}'
            : selected.split('/').where((part) => part.isNotEmpty).last;
        ref
            .read(repositoryContextSupplementCacheProvider.notifier)
            .publish(
              RepositoryContextSupplementKey(
                repositoryIdentity: repositoryContextIdentityKey(
                  backend: connection.backend.name,
                  connectionId: connection.connectionId,
                  repositoryPath: repoPath,
                ),
                sessionEpoch: connection.sessionEpoch,
              ),
              RepositoryContextSupplement(worktreeLabel: label),
            );
      });
      final paths = live.map((w) => w.path).toSet();
      final dead = tabs.open.where((p) => !paths.contains(p)).toList();
      if (dead.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(worktreeTabsProvider.notifier).retain(paths);
          // The explicit close paths (_closeTab/_remove/_move) release their
          // grants themselves; this sweep is the ONLY release for a worktree
          // that vanished externally (pruned, or removed in a terminal) —
          // without it the native security-scoped grant leaks until the
          // whole container is disposed.
          final access = ref.read(worktreeAccessProvider);
          for (final p in dead) {
            access.release(p);
          }
        });
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _strip(context, tabs, worktreesAsync.value ?? const []),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: tabs.selected == null
              ? _overview(context, worktreesAsync)
              : _workspace(context, tabs.selected!),
        ),
      ],
    );
  }

  /// The tab strip: Overview, then one tab per open worktree, then the toolbar.
  Widget _strip(
    BuildContext context,
    WorktreeTabs tabs,
    List<GitWorktree> all,
  ) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _tab(
                  context,
                  label: 'Overview',
                  icon: CupertinoIcons.square_grid_2x2,
                  selected: tabs.selected == null,
                  onTap: () =>
                      ref.read(worktreeTabsProvider.notifier).select(null),
                ),
                for (final path in tabs.open)
                  _tab(
                    context,
                    // Leaf directory name, never the full path: full paths are
                    // too long to scan and are the #1 labelling complaint about
                    // every other client's worktree list. The path is in the
                    // tooltip.
                    label: path.split('/').last,
                    icon: kWorktreeIcon,
                    tooltip: path,
                    selected: tabs.selected == path,
                    onTap: () =>
                        ref.read(worktreeTabsProvider.notifier).select(path),
                    onClose: () => _closeTab(path),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ToolIconButton(
            icon: CupertinoIcons.add,
            tooltip: 'Add worktree…',
            size: 16,
            onPressed: busy ? null : _add,
          ),
          const SizedBox(width: 4),
          ToolIconButton(
            icon: CupertinoIcons.refresh,
            tooltip: 'Refresh',
            size: 16,
            onPressed: _refresh,
          ),
          const SizedBox(width: 4),
          _hamburger(context, all),
        ],
      ),
    );
  }

  Widget _tab(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    String? tooltip,
    VoidCallback? onClose,
  }) {
    final typography = MacosTheme.of(context).typography;
    final tab = Tappable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        padding: EdgeInsets.fromLTRB(10, 0, onClose == null ? 10 : 4, 0),
        decoration: BoxDecoration(
          color: selected
              ? MacosColors.systemBlueColor.withValues(alpha: 0.18)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(
              icon,
              size: 13,
              color: selected
                  ? MacosColors.systemBlueColor
                  : MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: typography.body.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            if (onClose != null) ...[
              const SizedBox(width: 2),
              ToolIconButton(
                icon: CupertinoIcons.xmark,
                tooltip: 'Close tab',
                size: 11,
                onPressed: onClose,
              ),
            ],
          ],
        ),
      ),
    );
    return tooltip == null ? tab : MacosTooltip(message: tooltip, child: tab);
  }

  Widget _hamburger(BuildContext context, List<GitWorktree> all) {
    final stale = all.where((w) => w.isPrunable).length;
    return MacosPulldownButtonTheme(
      data: MacosPulldownButtonTheme.of(
        context,
      ).copyWith(iconColor: MacosColors.systemGrayColor),
      child: MacosPulldownButton(
        icon: CupertinoIcons.line_horizontal_3,
        items: [
          MacosPulldownMenuItem(
            title: Text(
              stale == 0 ? 'Prune stale worktrees' : 'Prune $stale stale…',
            ),
            onTap: busy ? null : _prune,
          ),
          MacosPulldownMenuItem(
            title: const Text('Repair worktree links'),
            onTap: busy
                ? null
                : () => runGuarded(
                    () =>
                        ref.read(gitServiceProvider).repairWorktrees(repoPath),
                  ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- overview

  Widget _overview(BuildContext context, AsyncValue<List<GitWorktree>> async) {
    return async.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (worktrees) {
        // Only the main worktree: this repo has no linked worktrees yet.
        if (worktrees.length <= 1) return _empty(context);
        return ListView.builder(
          itemCount: worktrees.length,
          itemBuilder: (context, i) => _row(context, worktrees[i]),
        );
      },
    );
  }

  Widget _row(BuildContext context, GitWorktree wt) {
    final typography = MacosTheme.of(context).typography;
    final open = ref.watch(worktreeTabsProvider).open.contains(wt.path);

    final (IconData icon, Color color) = switch (wt) {
      _ when wt.isPrunable => (
        CupertinoIcons.exclamationmark_triangle,
        MacosColors.systemRedColor,
      ),
      _ when wt.isMain => (CupertinoIcons.house, MacosColors.systemGreenColor),
      _ when wt.isDetached => (
        CupertinoIcons.scissors,
        MacosColors.systemOrangeColor,
      ),
      _ => (kWorktreeIcon, MacosColors.systemBlueColor),
    };

    return GestureDetector(
      onDoubleTap: () => _openWorktree(wt),
      onSecondaryTapUp: (d) => _contextMenu.show(
        context,
        d.globalPosition,
        _rowMenu(wt),
        width: 280,
      ),
      child: Container(
        color: open
            ? MacosColors.systemBlueColor.withValues(alpha: 0.08)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            MacosIcon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        wt.name,
                        style: typography.body.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      LabelChip(
                        wt.branchLabel,
                        color: MacosColors.systemBlueColor,
                      ),
                      if (wt.isMain) ...[
                        const SizedBox(width: 4),
                        const LabelChip(
                          'main worktree',
                          color: MacosColors.systemGreenColor,
                        ),
                      ],
                      if (wt.isLocked) ...[
                        const SizedBox(width: 4),
                        LabelChip(
                          wt.lockReason?.isNotEmpty ?? false
                              ? 'locked: ${wt.lockReason}'
                              : 'locked',
                          color: MacosColors.systemGrayColor,
                        ),
                      ],
                      if (wt.isPrunable) ...[
                        const SizedBox(width: 4),
                        const LabelChip(
                          'missing',
                          color: MacosColors.systemRedColor,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // Full path as the subtitle, so the label can stay short.
                    wt.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ],
              ),
            ),
            // A missing worktree gets its remedies inline, rather than hiding
            // them in a menu — it is a broken state the user wants gone.
            if (wt.isPrunable) ...[
              ToolIconButton(
                icon: CupertinoIcons.wrench,
                tooltip: 'Repair — I moved this folder',
                size: 15,
                onPressed: busy ? null : () => _repair(wt),
              ),
              const SizedBox(width: 4),
              ToolIconButton(
                icon: CupertinoIcons.trash,
                // `git worktree prune` is inherently global — there is no
                // per-path form — so the copy must not pretend this only
                // forgets this row. The confirm lists exactly what goes.
                tooltip: 'Prune — forget all missing worktrees…',
                size: 15,
                onPressed: busy ? null : _prune,
              ),
            ] else if (!wt.isMain)
              ToolIconButton(
                icon: CupertinoIcons.square_arrow_right,
                tooltip: open ? 'Go to tab' : 'Open worktree',
                size: 15,
                onPressed: () => _openWorktree(wt),
              ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MacosIcon(
              kWorktreeIcon,
              size: 40,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(height: 12),
            Text('No worktrees yet', style: typography.title3),
            const SizedBox(height: 6),
            Text(
              'A worktree is a second checkout of this repository in its own '
              'folder — so you can fix a bug on main without stashing the '
              'feature you are half-way through.',
              textAlign: TextAlign.center,
              style: typography.body.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
            const SizedBox(height: 16),
            AppPushButton(
              controlSize: ControlSize.large,
              onPressed: busy ? null : _add,
              child: const Text('Add Worktree…'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- workspace

  /// A worktree's own workspace: the existing panels, pointed at its path.
  ///
  /// This is the payoff of the codebase already being repoPath-parameterised —
  /// these are the very same widgets the main repository uses, unmodified, and
  /// every provider they read is a family keyed on repoPath, so their data
  /// isolates itself with no work at all.
  Widget _workspace(BuildContext context, String worktreePath) {
    final page = ref.watch(worktreeSubPageProvider(worktreePath));
    final visited = ref.watch(worktreeVisitedSubPagesProvider(worktreePath));
    // Only the frontmost worktree tab of the visible panel may install its
    // keyboard shortcuts — the others stay mounted underneath.
    final active = widget.isActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              for (final (i, sub) in _subPanels.indexed) ...[
                _tab(
                  context,
                  label: sub.$1,
                  icon: sub.$2,
                  selected: page == i,
                  onTap: () {
                    ref
                        .read(worktreeSubPageProvider(worktreePath).notifier)
                        .select(i);
                    ref
                        .read(
                          worktreeVisitedSubPagesProvider(
                            worktreePath,
                          ).notifier,
                        )
                        .visit(i);
                  },
                ),
                const SizedBox(width: 2),
              ],
              const Spacer(),
              MacosTooltip(
                message: worktreePath,
                child: Text(
                  worktreePath.split('/').last,
                  style: MacosTheme.of(context).typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: IndexedStack(
            index: page,
            children: [
              visited.contains(0)
                  ? RepoStatusView(
                      repoPath: worktreePath,
                      isActive: active && page == 0,
                    )
                  : const SizedBox.shrink(),
              visited.contains(1)
                  ? HistoryView(
                      repoPath: worktreePath,
                      isActive: active && page == 1,
                    )
                  : const SizedBox.shrink(),
              visited.contains(2)
                  ? BranchesView(
                      repoPath: worktreePath,
                      isActive: active && page == 2,
                    )
                  : const SizedBox.shrink(),
              visited.contains(3)
                  ? StashView(
                      repoPath: worktreePath,
                      isActive: active && page == 3,
                    )
                  : const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }
}
