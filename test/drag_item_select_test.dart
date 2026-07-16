// The canonical select-on-drag contract (DragItemDraggable.onDragSelect):
// picking an item up fires the panel's select hook exactly once, at drag
// start — and a plain click never fires it (clicks select via the row's own
// tap handler, not the drag path).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';

const _commit = DragCommit(
  GitCommit(
    hash: 'a1b2c3d4e5f6',
    shortHash: 'a1b2c3d',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-16T10:00',
    parents: [],
    subject: 'a change',
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onDragSelect,
  required VoidCallback onTap,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Center(
          child: DragItemDraggable(
            item: _commit,
            immediate: true,
            onDragSelect: onDragSelect,
            // Like every real drag source, the row has its own tap handler —
            // it competes in the gesture arena and claims plain clicks, so the
            // drag (and onDragSelect) only fire on actual movement.
            child: GestureDetector(
              onTap: onTap,
              child: const SizedBox(
                width: 120,
                height: 44,
                child: Center(child: Text('ROW')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starting a drag fires onDragSelect exactly once', (
    tester,
  ) async {
    var selects = 0;
    var taps = 0;
    await _pump(tester, onDragSelect: () => selects++, onTap: () => taps++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -30)); // exceed slop -> drag begins
    await tester.pump();
    expect(selects, 1, reason: 'selection lands the moment the drag starts');

    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selects, 1, reason: 'moving and releasing must not re-select');
    expect(taps, 0, reason: 'a drag is not also a click');
  });

  testWidgets('a plain click taps the row and does not fire onDragSelect', (
    tester,
  ) async {
    var selects = 0;
    var taps = 0;
    await _pump(tester, onDragSelect: () => selects++, onTap: () => taps++);

    await tester.tap(find.text('ROW'));
    await tester.pumpAndSettle();

    expect(taps, 1, reason: 'the row tap claims plain clicks');
    expect(selects, 0, reason: 'clicks select via the row tap, not the drag');
  });
}
