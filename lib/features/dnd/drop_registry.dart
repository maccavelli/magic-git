import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' show MacosColors, showMacosSheet;

import '../../core/forge/forge.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../common/actions.dart';
import '../common/context_menu.dart';
import '../common/prompt_text_sheet.dart';
import '../github/create_pr_sheet.dart';
import '../gitlab/create_mr_sheet.dart';
import '../worktrees/add_worktree_sheet.dart';
import '../worktrees/worktree_tabs.dart' show kWorktreeIcon;
import 'drag_item.dart';

/// The nav-rail drop zones, in sidebar order — so [DropZonePage.pageIndex]
/// equals the `IndexedStack` page index a drop should navigate to.
enum DropZoneId {
  repository,
  history,
  branches,
  stashes,
  forge,
  project,
  worktrees,
}

extension DropZonePage on DropZoneId {
  int get pageIndex => index;
}

/// Everything a drop action needs to run: the ambient [ref]/[context], the
/// active [repoPath], the shell's navigation ([selectPage]) and repo-refresh
/// ([refresh]) hooks, and a menu controller for the ambiguous/destructive case.
class DropContext {
  final WidgetRef ref;
  final BuildContext context;
  final String repoPath;
  final void Function(int pageIndex) selectPage;
  final VoidCallback refresh;
  final ContextMenuOverlay menu;

  const DropContext({
    required this.ref,
    required this.context,
    required this.repoPath,
    required this.selectPage,
    required this.refresh,
    required this.menu,
  });
}

/// One thing a payload can do when dropped on a zone. [verb] is the short label
/// the nav rail shows while dragging ("New branch"); [label] is the full menu
/// line used when a zone offers more than one action.
class DropAction {
  final String label;
  final String verb;
  final IconData icon;
  final bool destructive;

  /// Shown in the confirm dialog when [destructive]; falls back to a generic
  /// warning. Ignored for non-destructive actions.
  final String? confirmMessage;

  final Future<void> Function(DropContext ctx) run;

  const DropAction({
    required this.label,
    required this.verb,
    required this.icon,
    this.destructive = false,
    this.confirmMessage,
    required this.run,
  });
}

// ---- The registry ---------------------------------------------------------
//
// The canonical table mapping (payload, zone) -> actions. Adding a new
// drag-onto-nav workflow means adding a case here — no widget wiring changes.
// Actions are built without a [DropContext] (it's only needed to *run* them), so
// the same list serves acceptance checks, the rail relabel, and dispatch.

List<DropAction> _actionsFor(DragItem item, DropZoneId zone) {
  switch (zone) {
    case DropZoneId.branches:
      if (item is DragCommit) {
        final commit = item.commit;
        return [
          DropAction(
            label: 'New branch from ${commit.shortHash}',
            verb: 'New branch',
            icon: CupertinoIcons.arrow_branch,
            run: (ctx) => _newBranchFromCommit(ctx, commit),
          ),
        ];
      }
      return const [];
    case DropZoneId.worktrees:
      if (item is DragRef) {
        final branch = item.ref.shortName;
        return [
          DropAction(
            label: 'New worktree for $branch',
            verb: 'New worktree',
            icon: kWorktreeIcon,
            run: (ctx) => _newWorktreeFrom(ctx, branch),
          ),
        ];
      }
      if (item is DragCommit) {
        final commit = item.commit;
        return [
          DropAction(
            label: 'New worktree from ${commit.shortHash}',
            verb: 'New worktree',
            icon: kWorktreeIcon,
            run: (ctx) => _newWorktreeFrom(ctx, commit.hash),
          ),
        ];
      }
      return const [];
    case DropZoneId.forge:
      // Only a local branch can be a PR/MR source; a remote-tracking ref can't.
      if (item is DragRef && item.ref.isLocalBranch) {
        final branch = item.ref.shortName;
        return [
          DropAction(
            label: 'Create pull/merge request from $branch',
            verb: 'New PR / MR',
            icon: CupertinoIcons.cloud_upload,
            run: (ctx) => _createRequestFromBranch(ctx, branch),
          ),
        ];
      }
      return const [];
    case DropZoneId.repository:
      // Repository == the working copy on the current branch. A commit dropped
      // here is cherry-picked onto it (destructive: it commits + can conflict).
      if (item is DragCommit) {
        final commit = item.commit;
        return [
          DropAction(
            label: 'Cherry-pick ${commit.shortHash} into current branch',
            verb: 'Cherry-pick',
            icon: CupertinoIcons.doc_on_clipboard,
            destructive: true,
            confirmMessage:
                'Apply ${commit.shortHash} "${commit.subject}" onto the '
                'current branch? It stops if it conflicts, and ⌘Z undoes it.',
            run: (ctx) => _cherryPickIntoCurrent(ctx, commit),
          ),
        ];
      }
      // A stash dropped onto the working copy is restored into it — apply
      // (keep it) or pop (apply and remove). Two safe, undoable choices, so
      // this drop offers the verb menu rather than guessing.
      if (item is DragStash) {
        final stash = item.stash;
        return [
          DropAction(
            label: 'Apply ${stash.ref} (keep in list)',
            verb: 'Apply stash',
            icon: CupertinoIcons.tray_arrow_up,
            run: (ctx) => _applyStash(ctx, stash),
          ),
          DropAction(
            label: 'Pop ${stash.ref} (apply & remove)',
            verb: 'Pop stash',
            icon: CupertinoIcons.arrow_up_bin,
            run: (ctx) => _popStash(ctx, stash),
          ),
        ];
      }
      return const [];
    case DropZoneId.stashes:
      // Working-copy files dropped onto Stashes become a partial stash — only
      // those paths are parked, the rest of the tree stays. Reversible (pop),
      // and the new stash is immediately visible, so it runs without a confirm.
      if (item is DragFiles && item.paths.isNotEmpty) {
        final paths = item.paths;
        return [
          DropAction(
            label: 'Stash ${item.shortLabel}',
            verb: 'Stash files',
            icon: CupertinoIcons.tray_arrow_down,
            run: (ctx) => _stashFiles(ctx, paths),
          ),
        ];
      }
      return const [];
    // No nav-drop actions for these zones yet.
    case DropZoneId.history:
    case DropZoneId.project:
      return const [];
  }
}

/// Whether [zone] would accept [item] — the accept predicate and the nav rail's
/// "eligible" test.
bool canDrop(DragItem item, DropZoneId zone) =>
    _actionsFor(item, zone).isNotEmpty;

/// The short verb the nav rail shows on [zone] while [item] is being dragged,
/// or null when the zone can't accept it.
String? dropVerb(DragItem item, DropZoneId zone) {
  final actions = _actionsFor(item, zone);
  return actions.isEmpty ? null : actions.first.verb;
}

/// Dispatches a drop. A single non-destructive action runs immediately (then its
/// own handler navigates); anything ambiguous or destructive is presented as a
/// verb menu at [pos], with destructive entries confirmed first.
Future<void> runDrop(
  DragItem item,
  DropZoneId zone,
  DropContext ctx,
  Offset pos,
) async {
  final actions = _actionsFor(item, zone);
  if (actions.isEmpty) return;
  // One action needs no disambiguation menu — run it (confirming first if it's
  // destructive). Only genuinely ambiguous drops (>1 action) get the verb menu.
  if (actions.length == 1) {
    await _confirmAndRun(ctx, actions.first);
    return;
  }
  ctx.menu.show(ctx.context, pos, [
    for (final a in actions)
      ContextMenuItem(
        icon: a.icon,
        label: a.label,
        iconColor: a.destructive ? MacosColors.systemRedColor : null,
        onTap: () => _confirmAndRun(ctx, a),
      ),
  ], width: 260);
}

Future<void> _confirmAndRun(DropContext ctx, DropAction action) async {
  if (action.destructive) {
    final ok = await confirmAction(
      ctx.context,
      title: action.label,
      message:
          action.confirmMessage ??
          'This can rewrite history or discard work. Continue?',
      confirmLabel: 'Continue',
      destructive: true,
    );
    if (!ok) return;
  }
  await action.run(ctx);
}

// ---- Action handlers (each self-contained; reuses existing UI + services) ---

Future<void> _newBranchFromCommit(DropContext ctx, GitCommit commit) async {
  final name = await promptText(
    ctx.context,
    'New branch from commit',
    placeholder: 'branch name',
    description:
        'Creates a branch starting at ${commit.shortHash} and checks it out.',
  );
  if (name == null || !ctx.context.mounted) return;
  final git = ctx.ref.read(gitServiceProvider);
  final ok = await runAction(
    ctx.context,
    () => git.branchFrom(ctx.repoPath, name, commit.hash),
  );
  // Mounted check matches every other handler: the shell (and its hooks) can
  // be gone by the time the action resolves (disconnect mid-create).
  if (!ok || !ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.branches.pageIndex);
}

Future<void> _newWorktreeFrom(DropContext ctx, String commitish) async {
  // Reuse the exact sheet the Branches/History panels open for "checkout/branch
  // in a new worktree" — pre-seeded with the dropped branch or commit as the
  // start point. The sheet lets the user pick new-branch vs detached.
  await showMacosSheet<void>(
    context: ctx.context,
    builder: (_) =>
        AddWorktreeSheet(repoPath: ctx.repoPath, initialCommitish: commitish),
  );
  if (!ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.worktrees.pageIndex);
}

Future<void> _cherryPickIntoCurrent(DropContext ctx, GitCommit commit) async {
  final git = ctx.ref.read(gitServiceProvider);
  // A conflict throws (git_service records nothing and the pending-op abort
  // owns it), so runAction surfaces it in a dialog; a clean pick returns. For a
  // merge commit, default to the first parent (-m 1) rather than erroring.
  final ok = await runAction(
    ctx.context,
    () => git.cherryPick(
      ctx.repoPath,
      commit.hash,
      mainline: commit.isMerge ? 1 : null,
    ),
  );
  if (!ok || !ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.repository.pageIndex);
}

Future<void> _applyStash(DropContext ctx, GitStash stash) async {
  final git = ctx.ref.read(gitServiceProvider);
  // Addressed by OID: immune to the stash list shifting since it was rendered.
  // A conflict throws and runAction surfaces it in a dialog.
  final ok = await runAction(
    ctx.context,
    () => git.stashApply(ctx.repoPath, stash.oid),
  );
  if (!ok || !ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.repository.pageIndex);
}

Future<void> _popStash(DropContext ctx, GitStash stash) async {
  final git = ctx.ref.read(gitServiceProvider);
  // Pop verifies stash@{index} still resolves to this OID before dropping it
  // (StashStaleException otherwise, nothing touched); runAction shows either
  // the stale note or a conflict in a dialog. The refresh brings in the truth.
  final ok = await runAction(
    ctx.context,
    () => git.stashPop(ctx.repoPath, stash.index, expectedOid: stash.oid),
  );
  if (!ok || !ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.repository.pageIndex);
}

Future<void> _stashFiles(DropContext ctx, List<String> paths) async {
  final git = ctx.ref.read(gitServiceProvider);
  // Path-scoped stash. includeUntracked so dragging a brand-new (unadded) file
  // works too; with explicit pathspecs it only touches the dropped paths.
  final ok = await runAction(
    ctx.context,
    () => git.stashPush(ctx.repoPath, paths: paths, includeUntracked: true),
  );
  if (!ok || !ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.stashes.pageIndex);
}

Future<void> _createRequestFromBranch(DropContext ctx, String branch) async {
  // Which forge this repo talks to decides PR (GitHub) vs MR (GitLab). Resolve
  // it (cheap once the Forge tab has been visited) and open that forge's
  // existing create sheet, seeded with the dropped branch as the source.
  //
  // The resolution can hit the network and throw (host unreachable, gh/glab
  // missing) — and runDrop's future is fire-and-forget from the DragTarget, so
  // an escaped exception here would be an unhandled async error, not a dialog.
  final Forge forge;
  try {
    forge = await ctx.ref.read(forgeProvider(ctx.repoPath).future);
  } catch (e) {
    if (ctx.context.mounted) {
      await showErrorDialog(ctx.context, displayError(e));
    }
    return;
  }
  if (!ctx.context.mounted) return;
  switch (forge) {
    case Forge.github:
      await showMacosSheet<void>(
        context: ctx.context,
        builder: (_) =>
            CreatePrSheet(repoPath: ctx.repoPath, initialHead: branch),
      );
    case Forge.gitlab:
      await showMacosSheet<void>(
        context: ctx.context,
        builder: (_) =>
            CreateMrSheet(repoPath: ctx.repoPath, initialSource: branch),
      );
    case Forge.none:
    case Forge.unknown:
      await showErrorDialog(
        ctx.context,
        'No GitHub or GitLab remote detected for this repository.',
      );
      return;
  }
  if (!ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.forge.pageIndex);
}
