// Canonical deselect affordances (see lib/features/dnd/deselect.dart):
// DeselectOnEmptyClick must fire ONLY for clicks nothing deeper claims —
// row taps keep winning the gesture arena — and panel Esc handling is pinned
// end-to-end in the panel test files (repo_status_view_test.dart,
// stash_view_test.dart, branches_view_test.dart).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/features/dnd/deselect.dart';

void main() {
  testWidgets('a click on empty space deselects; a click on a row does not', (
    tester,
  ) async {
    var deselects = 0;
    var rowTaps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DeselectOnEmptyClick(
          onDeselect: () => deselects++,
          child: Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              onTap: () => rowTaps++,
              child: const SizedBox(width: 200, height: 40, child: Text('ROW')),
            ),
          ),
        ),
      ),
    );

    // On the row: the deeper tap recognizer wins the arena.
    await tester.tap(find.text('ROW'));
    await tester.pump();
    expect(rowTaps, 1);
    expect(deselects, 0);

    // Below the row — empty space: only the wrapper's recognizer is in play.
    await tester.tapAt(const Offset(100, 300));
    await tester.pump();
    expect(rowTaps, 1);
    expect(deselects, 1);
  });
}
