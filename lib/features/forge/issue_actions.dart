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
import '../common/prompt_form_sheet.dart';
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

  /// Refreshes the issue list, the selected issue's detail, and the dashboard
  /// (whose "N of M" count moves on close/reopen).
  ///
  /// Every caller gates this on `context.mounted`: it runs AFTER an awaited
  /// network mutation, and the captured [ref] is the panel's `WidgetRef` —
  /// invalidating through it once the panel is torn down (disconnect / window
  /// close mid-mutation) throws.
  void _invalidate(int id) {
    ref.invalidate(projectIssuesProvider(repoPath));
    ref.invalidate(issueDetailProvider((repoPath, id)));
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
    if (success && context.mounted) _invalidate(id);
  }

  Future<void> reopen(BuildContext context, int id) async {
    final success = await runAction(
      context,
      () => _isGithub
          ? ref.read(ghServiceProvider).reopenIssue(repoPath, id)
          : ref.read(glabServiceProvider).reopenIssue(repoPath, id),
    );
    if (success && context.mounted) _invalidate(id);
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

  /// Full title + description edit. Fetches the authoritative fields first (a
  /// row's ForgeIssue carries no body — the list query omits it), then opens
  /// the shared multi-field [promptForm].
  Future<void> edit(BuildContext context, ForgeIssue issue) async {
    final id = issue.id;
    if (id == null) return;
    ForgeIssue? current;
    final fetched = await runAction(context, () async {
      current = _isGithub
          ? await ref.read(ghServiceProvider).issueDetail(repoPath, id)
          : await ref.read(glabServiceProvider).issueDetail(repoPath, id);
    });
    if (!fetched || current == null || !context.mounted) return;
    final result = await promptForm(
      context,
      'Edit issue #$id',
      confirmLabel: 'Save',
      fields: [
        PromptField(
          key: 'title',
          label: 'Title',
          initial: current!.title,
          validate: (v) => v.isEmpty ? 'A title is required.' : null,
        ),
        PromptField(
          key: 'body',
          label: 'Description',
          initial: current!.body ?? '',
          placeholder: 'Describe the issue…',
          multiline: true,
        ),
      ],
    );
    if (result == null || !context.mounted) return;
    final title = result['title']!;
    final body = result['body']!;
    if (title == current!.title && body == (current!.body ?? '')) return;
    final success = await runAction(
      context,
      () => _isGithub
          ? ref
                .read(ghServiceProvider)
                .editIssue(repoPath, id, title: title, body: body)
          : ref
                .read(glabServiceProvider)
                .editIssue(repoPath, id, title: title, description: body),
    );
    if (success && context.mounted) _invalidate(id);
  }

  /// GitHub only (`gh issue edit --add-assignee @me`); the GitLab menu omits
  /// this (glab has no reliable current-user token for issue assignment).
  Future<void> assignToMe(BuildContext context, int id) async {
    final success = await runAction(
      context,
      () => ref.read(ghServiceProvider).assignIssueToMe(repoPath, id),
    );
    if (success && context.mounted) _invalidate(id);
  }

  /// "Start work": GitHub only — `gh issue develop --checkout` creates a real
  /// issue-linked branch and checks it out. GitLab has no issue→branch command
  /// and a bare local branch carries no forge link, so the action is hidden on
  /// GitLab entirely (see [issueContextMenu] / [IssueDetailActions]); this
  /// guards defensively against being called there. Switches the working tree,
  /// so it runs behind the dirty-tree guard and refreshes afterwards.
  Future<void> startWork(BuildContext context, ForgeIssue issue) async {
    final id = issue.id;
    if (id == null || !_isGithub) return;
    final gh = ref.read(ghServiceProvider);
    await guardedBranchSwitch(
      context,
      ref,
      repoPath,
      () => gh.developIssueBranch(repoPath, id),
    );
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
      // Start work is GitHub-only: `gh issue develop` makes a real linked
      // branch; GitLab has no equivalent, so it's hidden there.
      if (forge == Forge.github)
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
        label: 'Edit…',
        onTap: () => actions.edit(context, issue),
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
        // Start work is GitHub-only (see startWork) — hidden on GitLab.
        if (widget.forge == Forge.github)
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
              title: const Text('Edit…'),
              onTap: () => _run((a) => a.edit(context, issue)),
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
