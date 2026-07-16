import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drag_item.dart';

/// What is currently being dragged, or null when nothing is. Set by
/// [DragItemDraggable] on drag start and cleared on end, so reactive drop
/// targets — chiefly the nav rail — can highlight the zones that would accept
/// the payload the instant a drag begins (before the pointer reaches them).
///
/// **ESC cancels the drag**: while a drag is live a hardware-keyboard handler
/// clears this state on Escape. Flutter can't abort the gesture itself (the
/// ghost follows the pointer until release), but every drop target treats a
/// null drag state as "cancelled" and ignores the drop, and the nav rail
/// un-lights immediately — so ESC makes releasing anywhere a guaranteed no-op.
class DragStateNotifier extends Notifier<DragItem?> {
  bool _escHandlerInstalled = false;

  @override
  DragItem? build() {
    // A tab (container) can be torn down mid-drag; never leak the handler.
    ref.onDispose(_removeEscHandler);
    return null;
  }

  void begin(DragItem item) {
    state = item;
    if (!_escHandlerInstalled) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _escHandlerInstalled = true;
    }
  }

  /// Called on every drag end (drop or cancel). Idempotent — an ESC-cancelled
  /// drag still ends with a pointer release, which calls this again.
  void end() {
    state = null;
    _removeEscHandler();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        state != null) {
      state = null; // drop targets now ignore the release; the rail un-lights
      return true; // swallow it — this ESC must not also dismiss a sheet
    }
    return false;
  }

  void _removeEscHandler() {
    if (_escHandlerInstalled) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _escHandlerInstalled = false;
    }
  }
}

final dragStateProvider = NotifierProvider<DragStateNotifier, DragItem?>(
  DragStateNotifier.new,
);
