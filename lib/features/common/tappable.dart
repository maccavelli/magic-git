import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The canonical clickable surface for everything that is not a button:
/// list rows, chips, tabs, pills, links. Extends the cursor policy of
/// `common/buttons.dart` (pointing hand over anything clickable, arrow
/// otherwise) to plain tappable widgets, which macos_ui doesn't cover.
///
/// This is exactly the `MouseRegion` + `GestureDetector` sandwich that was
/// previously hand-rolled at each call site — single-sourced so a tappable
/// surface can't ship without the hand cursor again. Pinned two ways:
/// `tappable_cursor_test.dart` (behavior) and the source scan in
/// `button_cursor_canon_test.dart` (every `GestureDetector` with an `onTap:`
/// must be this widget or be allowlisted as a deliberate arrow surface —
/// scrims, window-drag title bars, scrubbers).
///
/// [behavior] is forwarded verbatim — full-row hit targets need
/// [HitTestBehavior.opaque], and silently changing a site's hit-test behavior
/// is the one way this wrapper could break things, so it takes no opinion.
///
/// [cursor] overrides the computed cursor for the rare non-hand case (e.g.
/// the undo toast's [MouseCursor.defer] while its hint is hidden). Without
/// it: hand when [onTap] is set, arrow when not — matching [AppPushButton]'s
/// enabled/disabled semantics.
class Tappable extends StatelessWidget {
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final GestureTapCancelCallback? onTapCancel;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureTapDownCallback? onSecondaryTapDown;
  final VoidCallback? onLongPress;
  final HitTestBehavior? behavior;
  final MouseCursor? cursor;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final Widget child;

  const Tappable({
    super.key,
    this.onTap,
    this.onDoubleTap,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.onSecondaryTapUp,
    this.onSecondaryTapDown,
    this.onLongPress,
    this.behavior,
    this.cursor,
    this.onEnter,
    this.onExit,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          cursor ??
          (onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic),
      onEnter: onEnter,
      onExit: onExit,
      child: GestureDetector(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onTapDown: onTapDown,
        onTapUp: onTapUp,
        onTapCancel: onTapCancel,
        onSecondaryTapUp: onSecondaryTapUp,
        onSecondaryTapDown: onSecondaryTapDown,
        onLongPress: onLongPress,
        behavior: behavior,
        child: child,
      ),
    );
  }
}
