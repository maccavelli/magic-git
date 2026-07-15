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

  const LabelChip(this.text, {super.key, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
