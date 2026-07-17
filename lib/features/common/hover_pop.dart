import 'package:flutter/widgets.dart';

/// The macOS-native "lift" microinteraction for prominent buttons: on hover
/// the control pops — scales up slightly and gains a soft shadow, visibly
/// rising toward the pointer (SwiftUI's `.hoverEffect(.lift)` idiom) — and on
/// click it presses in, dipping below resting scale the way a physical key
/// travels (SwiftUI's `configuration.isPressed` scale-down).
///
/// Timings follow the standard microinteraction guidance (NN/g and friends:
/// 100–250ms, ease-out, press-in faster than pop): hover pop 180ms; press-in
/// 90ms to 0.97; release springs back through a subtle ease-out-back
/// overshoot, which is what makes it read as a spring rather than a fade.
///
/// A wrapper, not a button: it observes raw pointer events ([Listener]), so
/// the wrapped control (a macos_ui PushButton here) keeps its own tap
/// handling, focus, and colors untouched. The shadow is painted behind the
/// child on [borderRadius] — pass the wrapped control's own radius so the
/// lift hugs its corners exactly.
class HoverPop extends StatefulWidget {
  final Widget child;

  /// When false (the wrapped button is disabled) the wrapper is inert: no
  /// pop, no press, no shadow.
  final bool enabled;

  /// The wrapped control's corner radius — default matches a
  /// `ControlSize.large` macos_ui PushButton.
  final BorderRadius borderRadius;

  const HoverPop({
    super.key,
    required this.child,
    this.enabled = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(7)),
  });

  @override
  State<HoverPop> createState() => _HoverPopState();
}

class _HoverPopState extends State<HoverPop> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled;
    final hovered = active && _hovered;
    final pressed = active && _pressed;

    final scale = pressed ? 0.97 : (hovered ? 1.02 : 1.0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          // Press-in is near-instant (the finger hit something solid);
          // pop/release take the scenic route with a whisper of overshoot —
          // the spring read.
          duration: Duration(milliseconds: pressed ? 90 : 180),
          curve: pressed ? Curves.easeOut : Curves.easeOutBack,
          child: AnimatedContainer(
            duration: Duration(milliseconds: pressed ? 90 : 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              boxShadow: hovered && !pressed
                  ? const [
                      // Lifted: a wide soft umbra plus a tight contact shadow
                      // — same two-layer language as the drag engine's lifted
                      // cell, scaled down to button size.
                      BoxShadow(
                        color: Color(0x59000000),
                        blurRadius: 14,
                        offset: Offset(0, 6),
                      ),
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
