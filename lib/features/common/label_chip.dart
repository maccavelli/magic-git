import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

/// The small tinted status chip used on list rows (a worktree's branch /
/// locked / missing state, a stash's `stash@{n}` ref, the "checked out in a
/// worktree" badge): colored text on a soft same-color background, with an
/// optional leading icon. Existed as byte-identical private copies in the
/// worktrees and stash views (stash's had the color hard-coded blue) plus an
/// icon-bearing purple variant in the branches view.
class LabelChip extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;

  /// Widest this chip may draw before its label ellipsizes.
  ///
  /// Chosen against the NARROWEST pane a user can drag to (240 pt,
  /// [RepositoryWorkspacePrefs.minNavigatorWidth]): 32 pt of row padding, a
  /// 16 pt icon and its 10 pt gap leave roughly 182 pt, so a chip that took
  /// all 160 would still leave the row's subject a readable remainder. In a
  /// flex row the chip gets its share and this is only the ceiling.
  final double maxWidth;

  static const double defaultMaxWidth = 160;

  const LabelChip(
    this.text, {
    super.key,
    required this.color,
    this.icon,
    this.maxWidth = defaultMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // A chip used to draw at whatever width its label wanted, so a long
      // branch name or a typed lock reason pushed the row past its pane — and
      // a Flex paints the excess OUTSIDE its bounds, over the next pane
      // (MADR 0049).
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            MacosIcon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          // Flexible INSIDE the chip's own bounded box, which is what lets
          // the label ellipsize. (History's ref_chip.dart warns against a
          // Flexible chip inside a min-sized strip, where it can collapse to
          // nothing; the bound here is what makes this safe.)
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
