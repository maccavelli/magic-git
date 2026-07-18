import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/forge/forge_urls.dart';
import '../../core/providers/app_providers.dart';
import '../common/actions.dart';
import '../common/branch_switch.dart';
import '../common/buttons.dart';
import '../common/context_menu.dart';
import '../common/prompt_text_sheet.dart';
import 'forge_widgets.dart';

/// Phase-3 issue management: the forge-dispatched mutations plus the two UI
/// surfaces (the row right-click menu and the detail action bar) that drive
/// them, shared by the GitHub and GitLab panels. Issues were view-only before
/// this; these turn the Forge tab into a place you can actually work an issue
/// from — close/reopen, comment, assign, edit, and "start work" (branch out).

/// Whether an issue-state string means "open" across both forges — GitHub
/// reports `OPEN`/`open`, GitLab `opened`.
bool forgeIssueIsOpen(String state) {
  final s = state.toLowerCase();
  return s == 'open' || s == 'opened';
}

/// The GitLab-fallback branch name for an issue: `<iid>-<slug>` — the same
/// shape GitLab's own "create branch from issue" produces. The title is
/// slugified (lowercased, non-alphanumerics collapsed to `-`) and
/// length-bounded; a title that slugifies to nothing falls back to just the
/// iid.
String issueBranchName(int iid, String title) {
  var slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 40) {
    slug = slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  }
  return slug.isEmpty ? '$iid' : '$iid-$slug';
}

/// Forge-dispatched issue mutations. Each runner owns its confirm/prompt
/// guardrail, error surfacing ([runAction]), and provider invalidation.
/// Construct one per action site from the panel's/detail's `ref` + forge.
class ForgeIssueActions {
  final WidgetRef ref;
  final String repoPath;
  final Forge forge;

  const ForgeIssueActions({
    required this.ref,
    required this.repoPath,
    required this.forge,
  });

  bool get _isGithub => forge == Forge.github;

  void _invalidate(int id) {
    ref.invalidate(projectIssuesProvider(repoPath));
    ref.invalidate(issueDetailProvider((repoPath, id)));
    // Issue counts live on the dashboard — refresh it so the section header's
    // "N of M" stays honest after a close/reopen.
    if (_isGithub) {
      ref.invalidate(githubProjectDashboardProvider(repoPath));
    } else {
      ref.invalidate(projectDashboardProvider(repoPath));
    }
  }

  Future<void> close(BuildContext context, int id) async {
    final ok = await confirmAction(
      context,
      title: 'Close issue',
      message: 'Close #$id? You can reopen it later.',
      confirmLabel: 'Close',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final success = await runAction(
      context,
      () => _isGithub
          ? ref.read(ghServiceProvider).closeIssue(repoPath, id)
          : ref.read(glabServiceProvider).closeIssue(repoPath, id),
    );
    if (success) _invalidate(id);
  }

  Future<void> reopen(BuildContext context, int id) async {
    final success = await runAction(
      context,
      () => _isGithub
          ? ref.read(ghServiceProvider).reopenIssue(repoPath, id)
          : ref.read(glabServiceProvider).reopenIssue(repoPath, id),
    );
    if (success) _invalidate(id);
  }

  Future<void> comment(BuildContext context, int id) async {
    final body = await promptText(
      context,
      'Comment on #$id',
      placeholder: 'Write a comment…',
      description:
          'Adds a comment to the issue on ${_isGithub ? 'GitHub' : 'GitLab'}.',
      confirmLabel: 'Comment',
    );
    if (body == null || !context.mounted) return;
    await runAction(
      context,
      () => _isGithub
          ? ref.read(ghServiceProvider).commentOnIssue(repoPath, id, body)
          : ref.read(glabServiceProvider).commentOnIssue(repoPath, id, body),
    );
    // Comments aren't rendered in the detail body — nothing to invalidate.
  }

  Future<void> editTitle(BuildContext context, ForgeIssue issue) async {
    final id = issue.id;
    if (id == null) return;
    final title = await promptText(
      context,
      'Edit title of #$id',
      placeholder: 'Issue title',
      initial: issue.title,
      confirmLabel: 'Save',
    );
    if (title == null || title == issue.title || !context.mounted) return;
    final success = await runAction(
      context,
      () => _isGithub
          ? ref.read(ghServiceProvider).editIssue(repoPath, id, title: title)
          : ref.read(glabServiceProvider).editIssue(repoPath, id, title: title),
    );
    if (success) _invalidate(id);
  }

  /// GitHub only (`gh issue edit --add-assignee @me`); the GitLab menu omits
  /// this (glab has no reliable current-user token for issue assignment).
  Future<void> assignToMe(BuildContext context, int id) async {
    final success = await runAction(
      context,
      () => ref.read(ghServiceProvider).assignIssueToMe(repoPath, id),
    );
    if (success) _invalidate(id);
  }

  /// "Start work": GitHub uses `gh issue develop --checkout` (a real linked
  /// branch); GitLab has no such command, so it falls back to a local branch
  /// named [issueBranchName] off HEAD. Both switch the working tree, so both
  /// run behind the dirty-tree guard ([guardedBranchSwitch]) and refresh the
  /// working-tree views afterwards.
  Future<void> startWork(BuildContext context, ForgeIssue issue) async {
    final id = issue.id;
    if (id == null) return;
    if (_isGithub) {
      final gh = ref.read(ghServiceProvider);
      await guardedBranchSwitch(
        context,
        ref,
        repoPath,
        () => gh.developIssueBranch(repoPath, id),
      );
    } else {
      final branch = issueBranchName(id, issue.title);
      // Make the fallback explicit — it creates a NEW local branch with no
      // forge-side link (unlike gh issue develop), so name it up front.
      final ok = await confirmAction(
        context,
        title: 'Start work on #$id',
        message:
            'GitLab has no issue→branch command. Create local branch "$branch" '
            'off the current HEAD and check it out?',
        confirmLabel: 'Create & check out',
      );
      if (!ok || !context.mounted) return;
      final git = ref.read(gitServiceProvider);
      await guardedBranchSwitch(
        context,
        ref,
        repoPath,
        () => git.createBranch(repoPath, branch),
      );
    }
    if (!context.mounted) return;
    refreshAfterMutation(ref, repoPath);
  }
}

/// The issue row's right-click menu — navigate (open/copy) → work (start
/// work / comment / assign / edit) → state (close / reopen). "Assign to me" is
/// GitHub-only. Built fresh per right-click from the panel's ref + forge.
List<ContextMenuEntry> issueContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String repoPath,
  required Forge forge,
  required ForgeIssue issue,
}) {
  final id = issue.id;
  final actions = ForgeIssueActions(ref: ref, repoPath: repoPath, forge: forge);
  final remoteUrl = ref.read(originRemoteUrlProvider(repoPath)).value;
  final url = (id != null && remoteUrl != null)
      ? forgeIssueWebUrl(remoteUrl, forge, id)
      : null;
  final isOpen = forgeIssueIsOpen(issue.state);
  return [
    ContextMenuItem(
      icon: CupertinoIcons.arrow_up_right_square,
      label: 'Open in browser',
      enabled: url != null,
      onTap: () => forgeOpenUrl(url),
    ),
    ContextMenuItem(
      icon: CupertinoIcons.link,
      label: 'Copy link',
      enabled: url != null,
      onTap: () => forgeCopy(url ?? ''),
    ),
    if (id != null)
      ContextMenuItem(
        icon: CupertinoIcons.number,
        label: 'Copy #$id',
        onTap: () => forgeCopy('#$id'),
      ),
    if (id != null) ...[
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_branch,
        label: 'Start work → create branch',
        onTap: () => actions.startWork(context, issue),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.text_bubble,
        label: 'Comment…',
        onTap: () => actions.comment(context, id),
      ),
      if (forge == Forge.github)
        ContextMenuItem(
          icon: CupertinoIcons.person_badge_plus,
          label: 'Assign to me',
          onTap: () => actions.assignToMe(context, id),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.pencil,
        label: 'Edit title…',
        onTap: () => actions.editTitle(context, issue),
      ),
      const ContextMenuDivider(),
      if (isOpen)
        ContextMenuItem(
          icon: CupertinoIcons.xmark_circle,
          label: 'Close',
          iconColor: MacosColors.systemRedColor,
          onTap: () => actions.close(context, id),
        )
      else
        ContextMenuItem(
          icon: CupertinoIcons.arrow_counterclockwise,
          label: 'Reopen',
          onTap: () => actions.reopen(context, id),
        ),
    ],
  ];
}

/// Shows [issueContextMenu] from a row's `onSecondaryTapUp`, via the panel's
/// shared [ContextMenuOverlay].
void showIssueContextMenu(
  ContextMenuOverlay menu, {
  required BuildContext context,
  required WidgetRef ref,
  required String repoPath,
  required Forge forge,
  required TapUpDetails details,
  required ForgeIssue issue,
}) {
  menu.show(
    context,
    details.globalPosition,
    issueContextMenu(
      context: context,
      ref: ref,
      repoPath: repoPath,
      forge: forge,
      issue: issue,
    ),
    width: 260,
  );
}

/// The issue detail pane's action bar: the same actions as the row menu, as
/// buttons + a "More" pulldown. Owns a single busy flag so a slow action (a
/// checkout-heavy "start work") can't be double-fired and the bar shows a
/// spinner while it runs.
class IssueDetailActions extends ConsumerStatefulWidget {
  final String repoPath;
  final Forge forge;
  final ForgeIssue issue;

  const IssueDetailActions({
    super.key,
    required this.repoPath,
    required this.forge,
    required this.issue,
  });

  @override
  ConsumerState<IssueDetailActions> createState() => _IssueDetailActionsState();
}

class _IssueDetailActionsState extends ConsumerState<IssueDetailActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(ForgeIssueActions) op) async {
    if (_busy) return;
    setState(() => _busy = true);
    final actions = ForgeIssueActions(
      ref: ref,
      repoPath: widget.repoPath,
      forge: widget.forge,
    );
    try {
      await op(actions);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.issue;
    final id = issue.id;
    if (id == null) return const SizedBox.shrink();
    // No spinner while _busy: an action's own confirm/prompt modal already
    // blocks re-entry, and swapping in an (infinitely animating) spinner while
    // that dialog is open would never settle. The `_busy` flag still guards
    // _run against a double-fire once the action is actually running.
    final isOpen = forgeIssueIsOpen(issue.state);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        AppPushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => _run((a) => a.startWork(context, issue)),
          child: const Text('Start work'),
        ),
        AppPushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => _run((a) => a.comment(context, id)),
          child: const Text('Comment'),
        ),
        if (isOpen)
          AppPushButton(
            controlSize: ControlSize.large,
            onPressed: () => _run((a) => a.close(context, id)),
            child: const Text('Close'),
          )
        else
          AppPushButton(
            controlSize: ControlSize.large,
            onPressed: () => _run((a) => a.reopen(context, id)),
            child: const Text('Reopen'),
          ),
        MacosPulldownButton(
          title: 'More',
          items: [
            MacosPulldownMenuItem(
              title: const Text('Edit title…'),
              onTap: () => _run((a) => a.editTitle(context, issue)),
            ),
            if (widget.forge == Forge.github)
              MacosPulldownMenuItem(
                title: const Text('Assign to me'),
                onTap: () => _run((a) => a.assignToMe(context, id)),
              ),
          ],
        ),
      ],
    );
  }
}
