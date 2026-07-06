import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';

/// A small colored label for a branch/remote/tag decorating a commit.
class RefChip extends StatelessWidget {
  final GitRef gitRef;

  const RefChip({super.key, required this.gitRef});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style(gitRef);
    return Container(
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
  }

  (Color, IconData) _style(GitRef ref) {
    if (ref.isTag) {
      return (MacosColors.systemOrangeColor, CupertinoIcons.tag);
    }
    if (ref.isRemote) {
      return (MacosColors.systemGrayColor, CupertinoIcons.cloud);
    }
    // Local branch (highlight the checked-out one).
    return (
      ref.isHead ? MacosColors.systemGreenColor : MacosColors.systemBlueColor,
      CupertinoIcons.arrow_branch,
    );
  }
}
