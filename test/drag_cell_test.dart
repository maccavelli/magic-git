// The canonical lift-cell interaction (drag_cell.dart + DragItemDraggable):
// pressing a row shows the pressed-cell affordance, dragging lifts the cell
// ghost under the pointer, and a cancelled drag flies it back home
// (SnapBackFlight) instead of blinking out. An accepted drop flies nothing.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
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

Future<void> _pump(WidgetTester tester, {bool withTarget = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            DragItemDraggable(
              item: _commit,
              immediate: true,
              child: GestureDetector(
                onTap: () {},
                child: const SizedBox(
                  width: 140,
                  height: 40,
                  child: Center(child: Text('ROW')),
                ),
              ),
            ),
            const SizedBox(width: 120),
            if (withTarget)
              DragTarget<DragItem>(
                onWillAcceptWithDetails: (_) => true,
                onAcceptWithDetails: (_) {},
                builder: (context, cand, rej) =>
                    const SizedBox(width: 90, height: 40, child: Text('T')),
              ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dragging lifts the canonical cell ghost under the pointer', (
    tester,
  ) async {
    await _pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();

    // The lifted cell (with the snapshot, or its identical-chrome label
    // fallback in fake-async tests) is in the overlay.
    expect(find.byType(LiftedDragCell), findsOneWidget);
    expect(find.byType(DragCellChrome), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a cancelled drag flies the cell home (snap-back flight)', (
    tester,
  ) async {
    await _pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.up(); // released over nothing -> cancelled
    await tester.pump();

    // The flight is up, animating back toward the source row...
    expect(find.byType(SnapBackFlight), findsOneWidget);

    // ...and settles clean (the flight removes its own overlay entry).
    await tester.pumpAndSettle();
    expect(find.byType(SnapBackFlight), findsNothing);
  });

  testWidgets('an accepted drop does not snap back', (tester) async {
    await _pump(tester, withTarget: true);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('T')));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(find.byType(SnapBackFlight), findsNothing);
    await tester.pumpAndSettle();
  });
}
