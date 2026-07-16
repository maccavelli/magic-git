import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' show MacosColors, showMacosSheet;

import '../../core/forge/forge.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
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
  final Future<void> Function(DropContext ctx) run;

  const DropAction({
    required this.label,
    required this.verb,
    required this.icon,
    this.destructive = false,
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
            run: (ctx) => _newWorktreeForBranch(ctx, branch),
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
    // No nav-drop actions yet (future phases add commit->Worktrees,
    // files->Stashes, etc.).
    case DropZoneId.repository:
    case DropZoneId.history:
    case DropZoneId.stashes:
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
  if (actions.length == 1 && !actions.first.destructive) {
    await actions.first.run(ctx);
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
      message: 'This can rewrite history or discard work. Continue?',
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
  if (!ok) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.branches.pageIndex);
}

Future<void> _newWorktreeForBranch(DropContext ctx, String branch) async {
  // Reuse the exact sheet the Branches panel opens for "checkout in new
  // worktree" — pre-seeded with the dropped branch as the start point.
  await showMacosSheet<void>(
    context: ctx.context,
    builder: (_) =>
        AddWorktreeSheet(repoPath: ctx.repoPath, initialCommitish: branch),
  );
  if (!ctx.context.mounted) return;
  ctx.refresh();
  ctx.selectPage(DropZoneId.worktrees.pageIndex);
}

Future<void> _createRequestFromBranch(DropContext ctx, String branch) async {
  // Which forge this repo talks to decides PR (GitHub) vs MR (GitLab). Resolve
  // it (cheap once the Forge tab has been visited) and open that forge's
  // existing create sheet, seeded with the dropped branch as the source.
  final forge = await ctx.ref.read(forgeProvider(ctx.repoPath).future);
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
