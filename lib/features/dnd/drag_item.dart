import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import 'drag_state.dart';

/// The unified drag payload vocabulary. Every draggable surface in the app
/// carries a [DragItem] so one drop engine ([DropZone] + the drop registry) can
/// reason about what was picked up regardless of where it came from. Sealed so
/// new payloads (files, stashes, worktrees) are added in one place as later
/// phases land.
sealed class DragItem {
  const DragItem();

  /// A short human label for the default drag ghost.
  String get shortLabel;
}

/// A branch (local or remote) — the operand for merge/rebase and worktree drops.
class DragRef extends DragItem {
  final GitRef ref;
  const DragRef(this.ref);
  @override
  String get shortLabel => ref.shortName;
}

/// A single commit from the history graph — the operand for branch/tag drops.
class DragCommit extends DragItem {
  final GitCommit commit;
  const DragCommit(this.commit);
  @override
  String get shortLabel => '${commit.shortHash}  ${commit.subject}';
}

/// Wraps [child] so it can be dragged as a [DragItem]. Row-sized sources use the
/// default long-press activation so the enclosing list still scrolls vertically;
/// small targets (chips) pass [immediate] to start on touch. Drives
/// [dragStateProvider] on start/end so reactive drop targets (the nav rail) can
/// light up while a drag is live.
class DragItemDraggable extends ConsumerWidget {
  final DragItem item;
  final Widget child;

  /// Custom drag ghost. Defaults to a small pill of [DragItem.shortLabel].
  final Widget? feedback;

  /// Start dragging immediately (small chips) instead of on long-press (rows).
  final bool immediate;

  const DragItemDraggable({
    super.key,
    required this.item,
    required this.child,
    this.feedback,
    this.immediate = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ghost = feedback ?? _defaultGhost(context);
    void begin() => ref.read(dragStateProvider.notifier).begin(item);
    void end() => ref.read(dragStateProvider.notifier).end();

    if (immediate) {
      return Draggable<DragItem>(
        data: item,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: begin,
        onDragEnd: (_) => end(),
        feedback: ghost,
        childWhenDragging: Opacity(opacity: 0.4, child: child),
        child: child,
      );
    }
    return LongPressDraggable<DragItem>(
      data: item,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: begin,
      onDragEnd: (_) => end(),
      feedback: ghost,
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }

  Widget _defaultGhost(BuildContext context) {
    // Offset from the pointer so the label isn't hidden under the cursor, and
    // width-capped so a long commit subject can't paint a page-wide pill.
    return Transform.translate(
      offset: const Offset(8, 8),
      child: Opacity(
        opacity: 0.9,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: MacosColors.separatorColor),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                item.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MacosTheme.of(context).typography.caption1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
