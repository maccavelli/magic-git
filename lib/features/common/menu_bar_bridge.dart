/// The Dart half of the native menu bar: what the menus may run right now, and
/// what the user just chose.
///
/// Both directions are per-tab state, because each tab has its own repository,
/// its own connection and its own panel. `TabsHost` owns the single native
/// channel and points it at whichever tab is active.
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The action ids the currently-active panel can run this frame.
///
/// Published by [PanelShortcuts] — the one place every panel already routes
/// its handler map through — so availability is derived from the real handlers
/// (a null value means "known but currently unavailable", the convention
/// `resolveShortcuts` uses) rather than from a second, forkable set of guards.
///
/// Exactly one panel publishes at a time: an inactive or busy panel passes an
/// empty handler map, and only the panel that last published a non-empty set
/// may clear it, so a background panel's teardown cannot blank the live one's
/// availability.
class AvailableActions extends Notifier<Set<String>> {
  Object? _owner;

  @override
  Set<String> build() => const {};

  void publish(Object owner, Set<String> ids) {
    if (ids.isEmpty) {
      if (_owner != null && !identical(_owner, owner)) return;
      _owner = null;
    } else {
      _owner = owner;
    }
    if (!setEquals(state, ids)) state = ids;
  }

  /// Called when a publishing panel is disposed. Deferred past the widget
  /// life-cycle by the caller, so by the time it runs the provider itself may
  /// already be gone with its container.
  void release(Object owner) {
    if (!ref.mounted) return;
    if (identical(_owner, owner)) publish(owner, const {});
  }
}

final availableActionsProvider = NotifierProvider<AvailableActions, Set<String>>(
  AvailableActions.new,
);

/// A menu-bar choice waiting to be routed to its owning panel.
///
/// Carries a monotonic token so choosing the same command twice in a row is
/// two distinct requests rather than one unchanged state.
class MenuActionRequest {
  final String actionId;
  final int token;

  const MenuActionRequest(this.actionId, this.token);
}

class MenuActionRequests extends Notifier<MenuActionRequest?> {
  @override
  MenuActionRequest? build() => null;

  void request(String actionId) =>
      state = MenuActionRequest(actionId, (state?.token ?? 0) + 1);
}

final menuActionRequestProvider =
    NotifierProvider<MenuActionRequests, MenuActionRequest?>(
      MenuActionRequests.new,
    );
