import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/git/git_service.dart';
import 'drag_cell.dart';
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

/// A stash entry — the operand for apply/pop drops onto the working copy
/// (the Repository zone).
class DragStash extends DragItem {
  final GitStash stash;
  const DragStash(this.stash);
  @override
  String get shortLabel => stash.subject.isEmpty ? stash.ref : stash.subject;
}

/// One or more working-copy paths — the operand for a partial (path-scoped)
/// stash when dropped onto the Stashes zone, and for drag-to-stage within the
/// Repository panel. Carries the whole current selection when the dragged row
/// is part of it, else just that one path.
///
/// [fromStaged] records whether the drag started in the Staged section. It's
/// what makes drag-to-stage directional: an unstaged/untracked source can only
/// be *staged*, a staged source can only be *unstaged* — so the drop target is
/// unambiguous even when the destination section is empty. The Stashes drop
/// ignores it.
class DragFiles extends DragItem {
  final List<String> paths;
  final bool fromStaged;
  const DragFiles(this.paths, {this.fromStaged = false});
  @override
  String get shortLabel =>
      paths.length == 1 ? _basename(paths.first) : '${paths.length} files';
}

/// Last path segment, for a compact drag label. Splits on '/' (POSIX repos —
/// the only remote target) and tolerates a trailing slash.
String _basename(String path) {
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// Wraps [child] so it can be dragged as a [DragItem]. Drives
/// [dragStateProvider] on start/end so reactive drop targets (the nav rail) can
/// light up while a drag is live.
///
/// **The canonical lift-cell interaction** (see drag_cell.dart) — every drag
/// source gets it automatically, no per-site visuals:
///
///  1. **Press**: the row scales to 0.98 and a rounded macOS cell materializes
///     around it — the pressed-button affordance. A pixel-perfect snapshot of
///     the row is captured here (RepaintBoundary.toImage), so it's ready the
///     instant a drag starts.
///  2. **Lift**: on drag start the snapshot rides under the pointer inside the
///     elevated cell ([LiftedDragCell]), springing 0.98 → 1.03 with a deep
///     soft shadow — the item visibly detaches and floats. Grab-point
///     anchored: the cell is held exactly where it was picked up (clamped
///     into the cell for rows wider than [kDragCellMaxWidth]). The in-list
///     row dims to 0.55, its selection tint (via [onDragSelect]) showing
///     through.
///  3. **Land / snap back**: an accepted drop hands off to the target's
///     action; a cancelled drag (released over nothing, or ESC) flies the
///     cell back to the source row ([SnapBackFlight]) — it returns home
///     rather than blinking out.
///
/// Every current surface passes [immediate]: this is a macOS-only app, where
/// list scrolling is wheel/trackpad events (never a mouse click-drag on the
/// list body), so an immediate drag steals nothing — and a long-press-to-drag
/// is an undiscoverable mobile idiom with a mouse. Plain clicks still win:
/// the drag only claims the gesture after movement exceeds the slop. The
/// long-press variant is kept for any future touch surface.
class DragItemDraggable extends ConsumerStatefulWidget {
  final DragItem item;
  final Widget child;

  /// Start dragging on movement (mouse-first) instead of on long-press.
  final bool immediate;

  /// **The canonical select-on-drag hook.** Fired the instant the drag begins,
  /// before any drop target sees it. Every selectable drag source wires this
  /// to its panel's own click-select path so picking an item up *selects* it —
  /// the row shows the real selection bar (not just the drag dim), any other
  /// selection moves off, and there is never ambiguity about which item the
  /// drag is operating on. Panels should no-op when the item is already part
  /// of the current selection (so dragging a multi-selection doesn't collapse
  /// it to one row).
  final VoidCallback? onDragSelect;

  const DragItemDraggable({
    super.key,
    required this.item,
    required this.child,
    this.immediate = false,
    this.onDragSelect,
  });

  @override
  ConsumerState<DragItemDraggable> createState() => _DragItemDraggableState();
}

class _DragItemDraggableState extends ConsumerState<DragItemDraggable> {
  /// Isolates the row for the press-time snapshot.
  final GlobalKey _boundaryKey = GlobalKey();

  /// The row's live snapshot. Captured on pointer-down (ready by the time the
  /// drag crosses the slop), then RE-captured one frame after the drag starts —
  /// select-on-drag paints the selection bar in that frame, and the overlay
  /// cell (which subscribes via this notifier: a Draggable's feedback is built
  /// once, only listenables can update it) swaps to the selected-state pixels.
  /// Null until the first capture lands — the cell then falls back to a label,
  /// so a drag can never block on the capture.
  final ValueNotifier<ui.Image?> _snapshot = ValueNotifier(null);
  double _snapshotPixelRatio = 1;
  Size _sourceSize = Size.zero;

  /// Pressed-button state: pointer is down on the row, drag not yet started.
  bool _pressed = false;

  /// Hover state: pointer is over the row — drives the canonical hover tint
  /// and the open-hand cursor, the two standard "you can pick this up"
  /// signifiers (NN/g; macOS open/closed-hand convention).
  bool _hovered = false;

  /// Pins the closed-hand cursor for the whole drag (see [GrabbingCursor]).
  final GrabbingCursor _grabbing = GrabbingCursor();

  @override
  void dispose() {
    _grabbing.hide();
    _snapshot.value?.dispose();
    _snapshot.dispose();
    super.dispose();
  }

  /// Captures the row's pixels. Best-effort: any failure (mid-paint, detached,
  /// fake-async test environment) simply leaves the label fallback in place.
  Future<void> _capture() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    try {
      final image = await boundary.toImage(pixelRatio: ratio);
      if (!mounted) {
        image.dispose();
        return;
      }
      // Swap first, dispose the old image a frame later: the overlay cell may
      // be painting it at this very moment, and disposing an image out from
      // under an in-flight RawImage paint is a crash.
      final old = _snapshot.value;
      _snapshotPixelRatio = ratio;
      _sourceSize = boundary.size;
      _snapshot.value = image;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    } catch (_) {
      // Keep whatever snapshot (or fallback) we had.
    }
  }

  /// Grab-point anchoring: the cell is held exactly where the row was picked
  /// up, clamped inside the (possibly width-capped) cell so the pointer never
  /// ends up past its right edge. The inset collapses for sources narrower
  /// than twice the inset (small chips) — a clamp with min > max throws.
  Offset _anchor(Draggable<Object> _, BuildContext context, Offset position) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(position);
    final cellWidth = box.size.width.clamp(0.0, kDragCellMaxWidth);
    final inset = cellWidth >= 32 ? 16.0 : cellWidth / 2;
    return Offset(
      local.dx.clamp(inset, cellWidth - inset),
      local.dy.clamp(0.0, box.size.height),
    );
  }

  void _snapBack(Offset droppedTopLeft) {
    final box = _boundaryKey.currentContext?.findRenderObject();
    // The source row can be gone by now (list refreshed mid-drag) — then
    // there's nowhere to fly home to, and skipping is the honest visual.
    if (box is! RenderBox || !box.attached || !mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final home = box.localToGlobal(Offset.zero);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => SnapBackFlight(
        // The flight owns a clone: the live snapshot may be re-captured (or
        // this row disposed) while the flight is still mid-air.
        image: _snapshot.value?.clone(),
        pixelRatio: _snapshotPixelRatio,
        sourceSize: _sourceSize,
        fallbackLabel: widget.item.shortLabel,
        from: droppedTopLeft,
        to: home,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    // Capture the notifier, not `ref`: a watcher-driven refresh can unmount
    // this row MID-DRAG (its file stashed away, its stash popped by another
    // tab), and `ref.read` on a disposed element throws — which would leave
    // the drag state stuck and the nav rail lit forever. The notifier object
    // stays valid for the tab's lifetime; if the whole tab closed mid-drag,
    // clearing its state is moot, hence the swallow.
    final drag = ref.watch(dragStateProvider.notifier);
    void begin() {
      if (mounted && _pressed) setState(() => _pressed = false);
      // Select first, then arm the drag state: by the time the rail lights up,
      // the source row is already showing its real selection bar.
      widget.onDragSelect?.call();
      drag.begin(widget.item);
      // Closed-hand from pickup to release, wherever the ghost travels.
      _grabbing.show(context);
      // Select-on-drag just changed how this row paints (selection bar). The
      // press-time snapshot predates that — re-capture next frame so the
      // lifted cell carries the row in its SELECTED state.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_capture());
      });
    }

    void end(DraggableDetails details) {
      _grabbing.hide();
      var cancelled = false;
      try {
        // ESC nulls the drag state before the release. The DragTarget still
        // reports wasAccepted (its accept decision was made on entry, and its
        // guarded onAccept just no-ops), so the state is the only signal that
        // this "accepted" drop actually did nothing — and the cell should fly
        // home like any other cancelled drag instead of blinking out.
        cancelled = !drag.isActive;
        drag.end();
      } catch (_) {
        // Tab container disposed mid-drag — nothing left to clear.
      }
      // `details.offset` is the ghost's top-left at release — fly it home.
      if (!details.wasAccepted || cancelled) _snapBack(details.offset);
    }

    // The press chrome, painted OVER the row (foregroundDecoration — rows have
    // their own opaque selection tints that would cover a background border),
    // plus the pressed-button scale-down. Both settle back if the press ends
    // without a drag. The MouseRegion adds the two canonical hover
    // affordances: a faint highlight wash and the open-hand cursor (closing
    // while pressed) — together they signal grabbability before any drag
    // starts.
    final pressWrapped = MouseRegion(
      cursor: _pressed ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: (_) {
          setState(() => _pressed = true);
          // Fire-and-forget: ready by the time the drag starts.
          unawaited(_capture());
        },
        onPointerUp: (_) {
          if (_pressed) setState(() => _pressed = false);
        },
        onPointerCancel: (_) {
          if (_pressed) setState(() => _pressed = false);
        },
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kDragCellRadius),
              border: Border.all(
                color: _pressed
                    ? const Color(0xFF5A5A5E)
                    : const Color(0x005A5A5E),
              ),
              color: _pressed
                  ? const Color(0x14FFFFFF)
                  : _hovered
                  ? const Color(0x0AFFFFFF)
                  : const Color(0x00FFFFFF),
            ),
            child: RepaintBoundary(key: _boundaryKey, child: widget.child),
          ),
        ),
      ),
    );

    // The overlay ghost subscribes to the snapshot notifier: when the
    // post-drag-start re-capture lands (selection bar painted), the lifted
    // cell swaps to the selected-state pixels mid-flight, seamlessly. A
    // multi-file drag carries the whole selection but snapshots only the
    // grabbed row — the Finder-style count badge says what's really in hand.
    final item = widget.item;
    final badgeCount = item is DragFiles && item.paths.length > 1
        ? item.paths.length
        : null;
    final ghost = ValueListenableBuilder<ui.Image?>(
      valueListenable: _snapshot,
      builder: (context, image, _) => LiftedDragCell(
        image: image,
        pixelRatio: _snapshotPixelRatio,
        sourceSize: _sourceSize == Size.zero
            ? const Size(kDragCellMaxWidth / 2, 28)
            : _sourceSize,
        fallbackLabel: widget.item.shortLabel,
        badgeCount: badgeCount,
      ),
    );

    // Dimmed just enough to read "in flight" while the row's own selection
    // tint (applied via onDragSelect) still reads as selected underneath.
    final whenDragging = Opacity(opacity: 0.55, child: pressWrapped);

    if (widget.immediate) {
      return Draggable<DragItem>(
        data: widget.item,
        // One live drag at a time: the shared drag state is a single slot, and
        // a second simultaneous drag (a stray second pointer) would clobber it.
        maxSimultaneousDrags: 1,
        dragAnchorStrategy: _anchor,
        onDragStarted: begin,
        onDragEnd: end,
        feedback: ghost,
        childWhenDragging: whenDragging,
        child: pressWrapped,
      );
    }
    return LongPressDraggable<DragItem>(
      data: widget.item,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: _anchor,
      onDragStarted: begin,
      onDragEnd: end,
      feedback: ghost,
      childWhenDragging: whenDragging,
      child: pressWrapped,
    );
  }
}
