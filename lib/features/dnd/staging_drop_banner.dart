import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' show MacosColors, MacosIcon, MacosTheme;

import 'drag_item.dart';
import 'drag_state.dart';

/// The in-panel drag-to-stage target. Idle it's invisible (zero-size); while a
/// [DragFiles] drag is live it overlays a single directional drop banner —
/// **Stage** when the drag started in an unstaged/untracked section, **Unstage**
/// when it started in Staged. The direction comes from [DragFiles.fromStaged],
/// so there's exactly one valid action per drag and the target works even when
/// the destination section is empty (the "nothing staged yet" case a
/// section-header drop couldn't cover).
///
/// It's a plain in-panel [DragTarget] rather than a nav-rail [DropZone]: it
/// doesn't navigate, and it dispatches to the panel's own [onStage]/[onUnstage]
/// (which keep the selection and diff panel in sync) instead of the global drop
/// registry.
class StagingDropBanner extends ConsumerWidget {
  /// Stage the dropped [paths] — the panel's `stageMany`.
  final void Function(List<String> paths) onStage;

  /// Unstage the dropped [paths] — the panel's `unstageMany`.
  final void Function(List<String> paths) onUnstage;

  const StagingDropBanner({
    super.key,
    required this.onStage,
    required this.onUnstage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drag = ref.watch(dragStateProvider);
    // Only working-copy file drags get a staging target; anything else (or no
    // drag, or an ESC-cancelled one — the state nulls and this unmounts, so a
    // cancelled release has nothing to hit) leaves the list unobstructed.
    if (drag is! DragFiles || drag.paths.isEmpty) {
      return const SizedBox.shrink();
    }

    final toStage = !drag.fromStaged;
    final color = toStage
        ? MacosColors.systemGreenColor
        : MacosColors.systemOrangeColor;
    final count = drag.paths.length;
    final noun = count == 1 ? 'file' : 'files';
    final label = toStage ? 'Stage $count $noun' : 'Unstage $count $noun';
    final icon = toStage
        ? CupertinoIcons.plus_circle
        : CupertinoIcons.minus_circle;

    return DragTarget<DragItem>(
      onWillAcceptWithDetails: (details) => details.data is DragFiles,
      onAcceptWithDetails: (details) {
        // ESC does unmount this banner (the build watches the drag state), but
        // the rebuild lands a frame later — a release inside that frame would
        // still hit the old target. Same runtime guard as every DropZone.
        if (ref.read(dragStateProvider) is! DragFiles) return;
        final paths = (details.data as DragFiles).paths;
        if (toStage) {
          onStage(paths);
        } else {
          onUnstage(paths);
        }
      },
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.all(8),
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: hovering ? 0.28 : 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: hovering ? 0.95 : 0.5),
              width: hovering ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              MacosIcon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MacosTheme.of(context).typography.body.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
