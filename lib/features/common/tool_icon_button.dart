import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

/// Canonical compact icon button for **small** inline actions.
///
/// Use this — not [PushButton], not a bare [MacosIconButton] — whenever the
/// affordance is an icon that must stay small and consistent with repository
/// row actions (stage / unstage / discard / refresh) and other toolbars.
///
/// Contract:
/// - Fixed visual language: icon + hover [MacosTooltip], no text label
/// - Default [size] is [smallSize] (17), matching stage/unstage rows
/// - Disabled state **dims** the icon instead of painting a solid fill
///   (macos_ui's default disabled fill reads as "selected")
///
/// Prefer a slightly smaller [size] only when the chrome is denser than a
/// status row (e.g. banner dismiss at 13). Prefer larger only for primary
/// toolbars that already use 18.
class ToolIconButton extends StatelessWidget {
  /// Default glyph size for compact row/toolbar actions (stage, unstage, …).
  static const double smallSize = 17;

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  const ToolIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = smallSize,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    // MacosIconButton paints a solid `disabledColor` fill behind a disabled
    // icon — indistinguishable from a "selected/pressed" background. Several
    // toolbar buttons share one guard flag (e.g. Fetch/Pull/Push/Sync behind
    // `_busy`), so disabling one disables them all at once; with a solid fill
    // that reads as every other icon suddenly looking selected. Dim the icon
    // instead of filling the background, so a disabled button just looks
    // faded rather than "selected".
    final disabled = onPressed == null;
    return MacosTooltip(
      message: tooltip,
      child: Opacity(
        opacity: disabled ? 0.35 : 1.0,
        child: MacosIconButton(
          icon: MacosIcon(icon, size: size, color: color),
          padding: const EdgeInsets.all(6),
          disabledColor: const Color(0x00000000),
          // Canonical cursor policy (see common/buttons.dart): pointing hand
          // over anything clickable, arrow when disabled.
          mouseCursor: disabled
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          onPressed: onPressed,
        ),
      ),
    );
  }
}
