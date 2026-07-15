import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

/// The inline "Show more" control at the bottom of a truncated list — the
/// panel-list counterpart of the diff view's "Show N lines" gap rows
/// (`commit_patch_view.dart`), and styled to read as the same idiom: a small
/// chevron and a blue label on a faint blue band, with the whole row as the
/// hit target (an 11px chevron is a miserable thing to aim at).
///
/// Set [busy] while the click's load is in flight: the chevron becomes a
/// spinner, the row goes grey and inert, and [label] should say what's
/// loading. Used by the branches panel's tags list and the Forge panels'
/// pipeline / workflow-run lists.
class ShowMoreRow extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  const ShowMoreRow({
    super.key,
    required this.label,
    this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = busy ? MacosColors.systemGrayColor : MacosColors.systemBlueColor;
    final tap = busy ? null : onTap;
    return MouseRegion(
      cursor: tap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: tap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: busy
              ? MacosColors.systemGrayColor.withValues(alpha: 0.08)
              : const Color(0x14007AFF),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              if (busy)
                const SizedBox(width: 11, height: 11, child: ProgressCircle())
              else
                MacosIcon(CupertinoIcons.chevron_down, size: 11, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MacosTheme.of(
                    context,
                  ).typography.caption1.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
