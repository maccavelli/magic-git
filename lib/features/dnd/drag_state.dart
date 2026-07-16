import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drag_item.dart';

/// What is currently being dragged, or null when nothing is. Set by
/// [DragItemDraggable] on drag start and cleared on end, so reactive drop
/// targets — chiefly the nav rail — can highlight the zones that would accept
/// the payload the instant a drag begins (before the pointer reaches them).
class DragStateNotifier extends Notifier<DragItem?> {
  @override
  DragItem? build() => null;

  void begin(DragItem item) => state = item;
  void end() => state = null;
}

final dragStateProvider = NotifierProvider<DragStateNotifier, DragItem?>(
  DragStateNotifier.new,
);
