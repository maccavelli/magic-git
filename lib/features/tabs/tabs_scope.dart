import 'package:flutter/widgets.dart';

import 'tabs_controller.dart';

/// Exposes the app's [TabsController] to the widget tree and rebuilds dependents
/// when the tab set / active tab changes. A plain [InheritedNotifier] (not a
/// Riverpod provider) because the controller owns imperative per-tab
/// [ProviderContainer] resources, not reactive provider state.
class TabsScope extends InheritedNotifier<TabsController> {
  const TabsScope({
    super.key,
    required TabsController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Subscribes the caller to tab-set changes.
  static TabsController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TabsScope>();
    assert(scope != null, 'No TabsScope in the widget tree');
    return scope!.notifier!;
  }

  /// Reads the controller without subscribing — for one-off actions from
  /// callbacks (open/close/activate a tab).
  static TabsController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<TabsScope>();
    assert(scope != null, 'No TabsScope in the widget tree');
    return scope!.notifier!;
  }
}
