import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';

/// A small colored label for a branch/remote/tag decorating a commit.
class RefChip extends StatelessWidget {
  final GitRef gitRef;

  const RefChip({super.key, required this.gitRef});

  /// Checked out in a worktree OTHER than this one. `%(worktreepath)` is set for
  /// the current worktree too (git's docs say otherwise, but it is), so [isHead]
  /// — which means "checked out *here*" — is what excludes it.
  bool get _inOtherWorktree =>
      gitRef.isLocalBranch && !gitRef.isHead && gitRef.worktreePath != null;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style(gitRef);
    final chip = Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MacosIcon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            gitRef.isHead && gitRef.isLocalBranch
                ? '${gitRef.shortName}  HEAD'
                : gitRef.shortName,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
    // Before worktrees there was exactly one HEAD, so a plain blue chip meant
    // "not checked out". That is no longer true: another worktree may have this
    // branch checked out, with its own HEAD sitting here. Name the worktree
    // rather than leaving it looking idle.
    if (!_inOtherWorktree) return chip;
    return MacosTooltip(
      message:
          'Checked out in the worktree at ${gitRef.worktreePath}',
      child: chip,
    );
  }

  (Color, IconData) _style(GitRef ref) {
    if (ref.isTag) {
      return (MacosColors.systemOrangeColor, CupertinoIcons.tag);
    }
    if (ref.isRemote) {
      return (MacosColors.systemGrayColor, CupertinoIcons.cloud);
    }
    // Checked out in another worktree — a second HEAD, in effect. Purple, with
    // the worktree glyph, matching the badge the Branches panel puts on it.
    if (_inOtherWorktree) {
      return (MacosColors.systemPurpleColor, CupertinoIcons.square_split_2x1);
    }
    // Local branch (highlight the checked-out one).
    return (
      ref.isHead ? MacosColors.systemGreenColor : MacosColors.systemBlueColor,
      CupertinoIcons.arrow_branch,
    );
  }
}
