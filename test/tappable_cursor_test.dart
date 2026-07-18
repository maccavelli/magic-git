// Pins the Tappable contract (see lib/features/common/tappable.dart): the
// canonical cursor policy for non-button clickables — pointing hand when
// tappable, arrow when inert, override respected — and that the gesture
// plumbing it wraps still works (tap fires, behavior is forwarded verbatim).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/features/common/tappable.dart';

Future<void> _pump(WidgetTester tester, Tappable tappable) async {
  await tester.pumpWidget(
    Directionality(textDirection: TextDirection.ltr, child: tappable),
  );
}

MouseRegion _region(WidgetTester tester) => tester.widget<MouseRegion>(
  find.descendant(of: find.byType(Tappable), matching: find.byType(MouseRegion)),
);

const _child = SizedBox(width: 100, height: 40, child: Center(child: Text('T')));

void main() {
  testWidgets('hand when onTap is set, arrow when not', (tester) async {
    await _pump(tester, Tappable(onTap: () {}, child: _child));
    expect(_region(tester).cursor, SystemMouseCursors.click);

    await _pump(tester, const Tappable(child: _child));
    expect(_region(tester).cursor, SystemMouseCursors.basic);
  });

  testWidgets('other gestures alone do not earn the hand', (tester) async {
    // A double-tap/right-click-only surface keeps the arrow (e.g. the
    // worktree row) — the hand promises single-click activation.
    await _pump(tester, Tappable(onDoubleTap: () {}, child: _child));
    expect(_region(tester).cursor, SystemMouseCursors.basic);
  });

  testWidgets('explicit cursor overrides the computed one', (tester) async {
    await _pump(
      tester,
      Tappable(onTap: () {}, cursor: MouseCursor.defer, child: _child),
    );
    expect(_region(tester).cursor, MouseCursor.defer);
  });

  testWidgets('tap fires and behavior is forwarded', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      Tappable(
        onTap: () => taps++,
        behavior: HitTestBehavior.opaque,
        child: _child,
      ),
    );
    expect(tester.widget<GestureDetector>(find.byType(GestureDetector)).behavior,
        HitTestBehavior.opaque);

    await tester.tap(find.byType(Tappable));
    expect(taps, 1);

    // Opaque behavior: the whole bounds are a hit target, not just the text.
    await tester.tapAt(tester.getTopLeft(find.byType(Tappable)) +
        const Offset(2, 2));
    expect(taps, 2);
  });
}
