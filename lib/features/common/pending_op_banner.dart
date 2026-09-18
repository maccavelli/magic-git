import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/ssh/ssh_command_executor.dart';
import 'actions.dart';
import 'inline_action_button.dart';

/// The paused operation's name, for labels: "Merge", "Rebase", …
String pendingOpVerb(PendingOp op) => switch (op) {
  PendingOp.merge => 'Merge',
  PendingOp.cherryPick => 'Cherry-pick',
  PendingOp.revert => 'Revert',
  PendingOp.rebase => 'Rebase',
  PendingOp.am => 'Patch application',
  PendingOp.none => '',
};

/// The confirmation every host shows before aborting.
Future<bool> confirmAbortPendingOp(BuildContext context, PendingOp op) {
  final verb = pendingOpVerb(op);
  return confirmAction(
    context,
    title: 'Abort $verb',
    message:
        'Abort the in-progress ${verb.toLowerCase()} and discard its changes?',
    confirmLabel: 'Abort',
  );
}

/// The `--abort` matching [op]. Hosts run it inside their own busy gate.
Future<void> abortPendingOp(GitService git, String repoPath, PendingOp op) =>
    switch (op) {
      PendingOp.merge => git.mergeAbort(repoPath),
      PendingOp.cherryPick => git.cherryPickAbort(repoPath),
      PendingOp.revert => git.revertAbort(repoPath),
      PendingOp.rebase => git.rebaseAbort(repoPath),
      PendingOp.am => git.amAbort(repoPath),
      PendingOp.none => Future<void>.value(),
    };

/// The `--continue` matching [op] and its log label, or null for
/// [PendingOp.none]. The prepared message (MERGE_MSG / the sequencer's)
/// commits as-is, so a hand-resolved conflict needs no composer round-trip
/// (0009 M14). Hosts run it inside their own busy gate.
(String, Future<SSHCommandResult> Function(String))? continuePendingOp(
  GitService git,
  PendingOp op,
) => switch (op) {
  PendingOp.rebase => ('git rebase --continue', git.rebaseContinue),
  PendingOp.merge => ('git merge --continue', git.mergeContinue),
  PendingOp.cherryPick => (
    'git cherry-pick --continue',
    git.cherryPickContinue,
  ),
  PendingOp.revert => ('git revert --continue', git.revertContinue),
  PendingOp.am => ('git am --continue', git.amContinue),
  PendingOp.none => null,
};

/// Shown while a merge/cherry-pick/revert/rebase/am is mid-flight (usually
/// after a conflict), offering to continue or abort. Presentation only: the
/// host runs [onContinue]/[onAbort] behind its own busy gate, because the
/// same actions are also reachable from the host's menus and shortcuts.
class PendingOpBanner extends StatelessWidget {
  const PendingOpBanner({
    super.key,
    required this.op,
    required this.onContinue,
    required this.onAbort,
  });

  final PendingOp op;
  final VoidCallback? onContinue;
  final VoidCallback? onAbort;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final verb = pendingOpVerb(op);
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
            onPressed: onContinue,
          ),
          const SizedBox(width: 8),
          InlineActionButton(
            label: 'Abort $verb',
            // Aborting throws the in-progress operation (and any conflict
            // resolution done so far) away — it gets the red.
            icon: CupertinoIcons.arrow_uturn_left,
            tone: InlineActionTone.destructive,
            onPressed: onAbort,
          ),
        ],
      ),
    );
  }
}
