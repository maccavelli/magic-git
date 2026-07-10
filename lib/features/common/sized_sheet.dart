import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// A [MacosSheet] whose requested [width]/[height] are actually honored.
///
/// [showMacosSheet]'s route lays its page out with *tight* full-screen
/// constraints, and [MacosSheet] merely pads them with
/// [MacosSheet.insetPadding] (140 px horizontal by default). Tight
/// constraints override any `SizedBox` *inside* the sheet, so every
/// "width:" the app ever passed there was silently ignored and each sheet
/// rendered at window-minus-margins. Centering *outside* the sheet loosens
/// the constraints first, which is what finally makes the requested size
/// real. Use this instead of a bare [MacosSheet] for any fixed-size sheet.
class SizedSheet extends StatelessWidget {
  final double width;

  /// Fixed height; when null the sheet wraps its content, capped near the
  /// window height (content with flex children still needs *some* bound).
  final double? height;
  final Widget child;

  const SizedSheet({
    super.key,
    required this.width,
    this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = height ?? (MediaQuery.sizeOf(context).height - 96);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: width,
          maxWidth: width,
          minHeight: height ?? 0.0,
          maxHeight: maxHeight,
        ),
        child: MacosSheet(
          // Size and placement are ours now; zero inset keeps only the
          // keyboard-avoidance behavior of the route's viewInsets.
          insetPadding: EdgeInsets.zero,
          child: child,
        ),
      ),
    );
  }
}
