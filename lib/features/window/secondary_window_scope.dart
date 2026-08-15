import 'package:flutter/widgets.dart';

/// Marks every widget below as living in a secondary (pop-out) window.
///
/// Native window-chrome helpers — `WindowManipulator`, and by extension
/// `TransparentMacOSSidebar`'s vibrancy subview — are main-window-only (see
/// the hard rule at the top of `secondary_window_main.dart`); shared feature
/// widgets consult this scope to fall back to opaque panes (0009 M26).
class SecondaryWindowScope extends InheritedWidget {
  const SecondaryWindowScope({super.key, required super.child});

  static bool isSecondary(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SecondaryWindowScope>() != null;

  @override
  bool updateShouldNotify(SecondaryWindowScope oldWidget) => false;
}
