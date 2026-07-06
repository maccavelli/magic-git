import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

/// A compact icon button with a consistent size and a hover tooltip — used for
/// every inline action across the app so the toolbar/row affordances read the
/// same and are all discoverable.
class ToolIconButton extends StatelessWidget {
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
    this.size = 17,
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
          onPressed: onPressed,
        ),
      ),
    );
  }
}
