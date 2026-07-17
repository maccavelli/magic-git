import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// The canonical drag-cell visual language, shared by every drag surface (the
/// [DragItemDraggable] engine sources and the rebase sheet's row drags), so a
/// picked-up item looks the same everywhere: a rounded, macOS-style elevated
/// cell containing the item's real content.
///
/// Grounded in the standard "lift" microinteraction (Trello/NN-g/Apple): on
/// grab the item gains elevation — scale up slightly, deep soft shadow — so it
/// reads as floating above the UI; ~100–150ms timings; and the ghost is the
/// item itself, not a tooltip-like label.

/// Max width a drag cell will take: a full-width panel row would be unwieldy
/// under the pointer, so wider content is cropped (leading edge kept — that's
/// where the identity lives: icon, hash, name).
const double kDragCellMaxWidth = 420;

/// Corner radius of the cell (press chrome and lifted ghost must match, so the
/// press visually *becomes* the lifted cell).
const double kDragCellRadius = 9;

/// The rounded macOS-style cell chrome: elevated surface, hairline border,
/// soft deep shadow. [lifted] chooses between the resting (in-list press) and
/// lifted (under-pointer ghost) looks.
class DragCellChrome extends StatelessWidget {
  final Widget child;
  final bool lifted;

  const DragCellChrome({super.key, required this.child, this.lifted = true});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Elevated surface a step above the panel background (dark theme —
        // the app pins ThemeMode.dark). Slight translucency keeps drop
        // targets readable through the cell as it passes over them.
        color: const Color(0xF2323236),
        borderRadius: BorderRadius.circular(kDragCellRadius),
        border: Border.all(
          color: lifted ? const Color(0xFF5A5A5E) : MacosColors.separatorColor,
        ),
        boxShadow: lifted
            ? const [
                // Two-layer shadow: a tight contact shadow plus a wide soft
                // umbra — the "floating above the UI" read.
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 22,
                  offset: Offset(0, 10),
                ),
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kDragCellRadius),
        child: child,
      ),
    );
  }
}

/// The static cell body: [DragCellChrome] around the source row's
/// pixel-perfect snapshot ([image], captured at press time via
/// RepaintBoundary.toImage). When no snapshot is available (capture raced the
/// drag, or a test's fake async never delivers the image), it degrades to
/// [fallbackLabel] in the same cell — chrome and motion stay identical.
class DragCellBody extends StatelessWidget {
  final ui.Image? image;

  /// The pixel ratio [image] was captured at (logical→physical), so it renders
  /// back at exactly its source's logical size.
  final double pixelRatio;
  final Size sourceSize;
  final String fallbackLabel;

  const DragCellBody({
    super.key,
    required this.image,
    required this.pixelRatio,
    required this.sourceSize,
    required this.fallbackLabel,
  });

  @override
  Widget build(BuildContext context) {
    final width = sourceSize.width.clamp(0.0, kDragCellMaxWidth).toDouble();
    final img = image;

    final content = img != null
        ? SizedBox(
            width: width,
            height: sourceSize.height,
            // BoxFit.none + leading alignment: wider-than-cap rows crop on the
            // right rather than squashing; the identity (icon/hash/name) lives
            // on the left.
            child: RawImage(
              image: img,
              scale: pixelRatio,
              fit: BoxFit.none,
              alignment: Alignment.centerLeft,
            ),
          )
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kDragCellMaxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                fallbackLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MacosTheme.of(context).typography.body,
              ),
            ),
          );

    return DragCellChrome(child: content);
  }
}

/// The lifted ghost that rides under the pointer, springing from the pressed
/// scale (0.98) up to a floating one (1.03) as it detaches from the list —
/// ~140ms ease-out per the microinteraction guidance; slight transparency so
/// drop targets stay readable underneath.
class LiftedDragCell extends StatelessWidget {
  final ui.Image? image;
  final double pixelRatio;
  final Size sourceSize;
  final String fallbackLabel;

  const LiftedDragCell({
    super.key,
    required this.image,
    required this.pixelRatio,
    required this.sourceSize,
    required this.fallbackLabel,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.98, end: 1.03),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Opacity(
        opacity: 0.94,
        child: DragCellBody(
          image: image,
          pixelRatio: pixelRatio,
          sourceSize: sourceSize,
          fallbackLabel: fallbackLabel,
        ),
      ),
    );
  }
}

/// Forces the macOS closed-hand ("grabbing") cursor for the whole lifetime of
/// a drag — the platform convention (open hand over a grabbable item, closed
/// hand from pickup to release). A [MouseRegion] on the source widget can't do
/// this: cursor resolution follows the pointer's hit test, so the moment the
/// ghost leaves the source row the cursor would revert to whatever it happens
/// to pass over. Instead [show] pins a full-screen, hit-test-transparent
/// region (`opaque: false` — it wins cursor resolution as the topmost overlay
/// entry but returns false from hitTest, so drop-target detection and
/// everything under it keep working) into the root overlay for the drag's
/// duration.
///
/// Each drag source owns one; [hide] is idempotent and safe after the overlay
/// is gone (tab closed mid-drag).
class GrabbingCursor {
  OverlayEntry? _entry;

  void show(BuildContext context) {
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (_) => const MouseRegion(
        cursor: SystemMouseCursors.grabbing,
        opaque: false,
        child: SizedBox.expand(),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  void hide() {
    try {
      _entry?.remove();
    } catch (_) {
      // The overlay (whole tab/window) was disposed mid-drag — nothing to
      // restore.
    }
    _entry = null;
  }
}

/// The snap-back flight: when a drag is cancelled (released over nothing, or
/// ESC), the cell animates from where it was dropped back to its source row
/// and settles — the item visibly returns home instead of blinking out.
/// Self-contained: owns its controller and removes itself via [onDone].
class SnapBackFlight extends StatefulWidget {
  final ui.Image? image;
  final double pixelRatio;
  final Size sourceSize;
  final String fallbackLabel;
  final Offset from;
  final Offset to;
  final VoidCallback onDone;

  const SnapBackFlight({
    super.key,
    required this.image,
    required this.pixelRatio,
    required this.sourceSize,
    required this.fallbackLabel,
    required this.from,
    required this.to,
    required this.onDone,
  });

  @override
  State<SnapBackFlight> createState() => _SnapBackFlightState();
}

class _SnapBackFlightState extends State<SnapBackFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 230),
  )..forward().whenCompleteOrCancel(widget.onDone);

  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void dispose() {
    _controller.dispose();
    // The flight owns its clone of the snapshot (see DragItemDraggable) —
    // release it with the flight.
    widget.image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) {
        final pos = Offset.lerp(widget.from, widget.to, _t.value)!;
        return Positioned(
          left: pos.dx,
          top: pos.dy,
          // Settle: the lift (1.03 scale, shadow) relaxes back to flat as the
          // cell lands, and it fades into the (still dimmed-until-drag-end,
          // then restored) source row.
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.94 - 0.5 * _t.value,
              child: Transform.scale(
                scale: 1.03 - 0.03 * _t.value,
                child: child,
              ),
            ),
          ),
        );
      },
      child: DragCellBody(
        image: widget.image,
        pixelRatio: widget.pixelRatio,
        sourceSize: widget.sourceSize,
        fallbackLabel: widget.fallbackLabel,
      ),
    );
  }
}
