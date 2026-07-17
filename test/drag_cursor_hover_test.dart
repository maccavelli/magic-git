// The two canonical grabbability signifiers on every DragItemDraggable
// (NN/g; macOS convention): (1) cursor semantics — open hand on hover, closed
// hand while pressed, and closed hand pinned for the WHOLE drag via the
// GrabbingCursor overlay; (2) a faint hover wash on the row itself.

import 'package:flutter/gestures.dart';
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

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: DragItemDraggable(
            item: _commit,
            immediate: true,
            // Like every real row, the child claims taps — so the immediate
            // drag recognizer has arena competition and the pressed state is
            // observable between pointer-down and drag-start.
            child: GestureDetector(
              onTap: () {},
              child: const SizedBox(
                width: 140,
                height: 40,
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

/// The draggable's own MouseRegion — the one whose cursor is grab/grabbing
/// (filters out any regions macos_ui adds around the app chrome).
Finder _handRegion() => find.byWidgetPredicate(
  (w) =>
      w is MouseRegion &&
      (w.cursor == SystemMouseCursors.grab ||
          w.cursor == SystemMouseCursors.grabbing),
);

MouseRegion _hand(WidgetTester tester) =>
    tester.widget<MouseRegion>(_handRegion().first);

/// The full-screen grabbing overlay pinned during a live drag.
Finder _grabbingOverlay() => find.byWidgetPredicate(
  (w) =>
      w is MouseRegion &&
      w.cursor == SystemMouseCursors.grabbing &&
      w.opaque == false,
);

/// The press/hover chrome painted over the row.
Decoration? _rowChrome(WidgetTester tester) {
  final c = tester.widget<AnimatedContainer>(
    find
        .ancestor(of: find.text('ROW'), matching: find.byType(AnimatedContainer))
        .first,
  );
  return c.foregroundDecoration;
}

void main() {
  testWidgets('open hand at rest, closed hand while pressed', (tester) async {
    await _pump(tester);
    expect(_hand(tester).cursor, SystemMouseCursors.grab);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(_hand(tester).cursor, SystemMouseCursors.grabbing);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_hand(tester).cursor, SystemMouseCursors.grab);
  });

  testWidgets('hover paints the wash; exit clears it', (tester) async {
    await _pump(tester);

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(tester.getCenter(find.text('ROW')));
    await tester.pumpAndSettle();
    expect(
      (_rowChrome(tester)! as BoxDecoration).color,
      const Color(0x0AFFFFFF),
    );

    await gesture.moveTo(const Offset(600, 500)); // off the row
    await tester.pumpAndSettle();
    expect(
      (_rowChrome(tester)! as BoxDecoration).color,
      const Color(0x00FFFFFF),
    );
  });

  testWidgets('the grabbing cursor is pinned for the whole drag and released '
      'on drop', (tester) async {
    await _pump(tester);
    expect(_grabbingOverlay(), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(200, 200)); // far off the source row
    await tester.pump();

    expect(
      _grabbingOverlay(),
      findsOneWidget,
      reason: 'the closed hand must persist wherever the ghost travels',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_grabbingOverlay(), findsNothing);
  });
}
