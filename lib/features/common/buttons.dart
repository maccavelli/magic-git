import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// **The canonical cursor policy for clickable controls.** Every enabled
/// button in Magic Git shows the macOS pointing hand ([SystemMouseCursors.
/// click]) on hover — instant "this is clickable" feedback; disabled controls
/// keep the arrow. Text keeps the I-beam, pane splitters keep resize arrows,
/// and draggable rows use grab/grabbing (the DnD engine's `GrabbingCursor`).
///
/// Why a wrapper instead of a MouseRegion at call sites: macos_ui buttons
/// carry their *own* inner `MouseRegion(cursor: SystemMouseCursors.basic)`,
/// and cursor resolution picks the deepest region under the pointer — so an
/// outer region can never win. The hand has to be injected through the
/// button's `mouseCursor` parameter, which is exactly what [AppPushButton]
/// (and `ToolIconButton` for icon buttons) do in one place.
///
/// Rules for new code, pinned by `button_cursor_canon_test.dart`:
///  * use [AppPushButton], never a raw `PushButton`;
///  * use `ToolIconButton` for toolbar/row icon actions; a raw
///    `MacosIconButton` must pass `mouseCursor:` explicitly.
///
/// Known gap: `MacosPulldownButton` hardcodes a basic-cursor region
/// internally and exposes no override, so pulldowns keep the arrow until
/// macos_ui grows a `mouseCursor` parameter.

/// A macos_ui [PushButton] with the canonical pointing-hand cursor when
/// enabled. Drop-in: all other parameters and defaults are forwarded
/// unchanged. A true subclass (not a wrapper) because macos_ui dialog APIs
/// ([MacosAlertDialog.primaryButton]) are typed `PushButton`; the constructor
/// is non-const because the cursor depends on whether [onPressed] is set.
class AppPushButton extends PushButton {
  // Not const by design: the cursor is computed from onPressed.
  // ignore: prefer_const_constructors_in_immutables
  AppPushButton({
    super.key,
    required super.child,
    required super.controlSize,
    super.onPressed,
    super.secondary,
    super.color,
    super.disabledColor,
    super.padding,
    super.pressedOpacity,
    super.borderRadius,
    super.alignment,
    super.semanticLabel,
  }) : super(
         mouseCursor: onPressed != null
             ? SystemMouseCursors.click
             : SystemMouseCursors.basic,
       );
}
