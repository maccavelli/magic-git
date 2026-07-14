import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';

/// The chips decorating one commit, laid out so they can never overflow the
/// commit list's right edge.
///
/// The commit list has a FIXED row height (`itemExtent`) — the graph painter
/// draws lane edges that must line up between adjacent rows, and the minimap
/// maps commits to y-positions assuming uniform rows. So chips cannot wrap onto
/// a second line; they have to fit on one.
///
/// Two things make that safe:
///
///  * The strip is a *flexible* child, so it takes only the room it needs and
///    at most its share. A rigid chip row beside an `Expanded` subject is what
///    used to push past the margin: once the chips' intrinsic width exceeded the
///    pane, the subject collapsed to zero and the surplus had nowhere to go.
///  * Past [maxVisible] chips the rest collapse into a `+N` chip, so a commit
///    that is the tip of a dozen refs doesn't squeeze the subject out entirely.
///    Hovering it lists them.
///
/// Worktrees made this visible: every branch checked out in another worktree now
/// carries a chip of its own, so commits routinely have several.
class RefChipStrip extends StatelessWidget {
  final List<GitRef> refs;

  /// Beyond this, chips collapse into a `+N`. Three fits comfortably in the
  /// 420px commit pane while leaving the subject legible.
  static const int maxVisible = 3;

  const RefChipStrip({super.key, required this.refs});

  @override
  Widget build(BuildContext context) {
    if (refs.isEmpty) return const SizedBox.shrink();
    final shown = refs.take(maxVisible).toList();
    final hidden = refs.sublist(shown.length);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in shown) Flexible(child: RefChip(gitRef: r)),
        if (hidden.isNotEmpty)
          MacosTooltip(
            message: hidden.map((r) => r.shortName).join('\n'),
            child: Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: MacosColors.systemGrayColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: MacosColors.systemGrayColor.withValues(alpha: 0.5),
                  width: 0.6,
                ),
              ),
              child: Text(
                '+${hidden.length}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

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
          // Flexible + ellipsis so a long branch name shrinks the chip instead
          // of forcing it to its full intrinsic width. Without this a chip is
          // rigid, and in a Row beside an Expanded subject the surplus width has
          // nowhere to go — it spills straight out past the pane's right edge.
          Flexible(
            child: Text(
              gitRef.isHead && gitRef.isLocalBranch
                  ? '${gitRef.shortName}  HEAD'
                  : gitRef.shortName,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
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
