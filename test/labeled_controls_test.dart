// Pins the labelled-control contract (lib/features/common/labeled_controls.dart):
// on macOS a checkbox/radio label is part of the control, so clicking the text
// activates it. macos_ui ships only the glyph, so this has to be rebuilt — and
// it must carry the same cursor policy as every other clickable surface.
//
// Enforcement is two-sided, matching the button canon: behaviour here, and a
// source scan in button_cursor_canon_test.dart that no call site regresses to
// a bare glyph plus an inert Text.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/labeled_controls.dart';
import 'package:remote_magic_git/features/common/tappable.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(width: 400, height: 200, child: child),
    ),
  );
  await tester.pumpAndSettle();
}

/// The label's own MouseRegion — same lookup tappable_cursor_test.dart uses.
MouseCursor _labelCursor(WidgetTester tester) => tester
    .widget<MouseRegion>(
      find.descendant(
        of: find.byType(Tappable),
        matching: find.byType(MouseRegion),
      ),
    )
    .cursor;

void main() {
  testWidgets('tapping a checkbox label toggles it', (tester) async {
    bool? received;
    await _pump(
      tester,
      LabeledCheckbox(
        label: 'Annotated tag',
        value: false,
        onChanged: (v) => received = v,
      ),
    );

    await tester.tap(find.text('Annotated tag'));
    await tester.pumpAndSettle();
    expect(received, isTrue);
  });

  testWidgets('a checked label toggles back off', (tester) async {
    bool? received;
    await _pump(
      tester,
      LabeledCheckbox(
        label: 'Annotated tag',
        value: true,
        onChanged: (v) => received = v,
      ),
    );

    await tester.tap(find.text('Annotated tag'));
    await tester.pumpAndSettle();
    expect(received, isFalse);
  });

  testWidgets('tapping a radio label selects that option', (tester) async {
    String? received;
    await _pump(
      tester,
      LabeledRadio<String>(
        label: 'Squash and merge',
        value: 'squash',
        groupValue: 'merge',
        onChanged: (v) => received = v,
      ),
    );

    await tester.tap(find.text('Squash and merge'));
    await tester.pumpAndSettle();
    expect(received, 'squash');
  });

  testWidgets('re-selecting the current radio option is a harmless no-op', (
    tester,
  ) async {
    var calls = 0;
    await _pump(
      tester,
      LabeledRadio<String>(
        label: 'Squash and merge',
        value: 'squash',
        groupValue: 'squash',
        onChanged: (_) => calls++,
      ),
    );

    await tester.tap(find.text('Squash and merge'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(calls, lessThanOrEqualTo(1));
  });

  testWidgets('an enabled label shows the pointing hand', (tester) async {
    await _pump(
      tester,
      LabeledCheckbox(
        label: 'Open it when done',
        value: false,
        onChanged: (_) {},
      ),
    );
    expect(_labelCursor(tester), SystemMouseCursors.click);
  });

  testWidgets('a disabled label is inert and keeps the arrow', (tester) async {
    // The submit-in-flight case (create_tag_sheet gates on _submitting): the
    // glyph is disabled, so the label must not offer a click either.
    await _pump(
      tester,
      const LabeledCheckbox(
        label: 'Annotated tag',
        value: false,
        onChanged: null,
      ),
    );

    expect(_labelCursor(tester), SystemMouseCursors.basic);
    await tester.tap(find.text('Annotated tag'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled radio label is inert too', (tester) async {
    await _pump(
      tester,
      const LabeledRadio<String>(
        label: 'Rebase and merge',
        value: 'rebase',
        groupValue: 'merge',
        onChanged: null,
      ),
    );
    await tester.tap(find.text('Rebase and merge'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_labelCursor(tester), SystemMouseCursors.basic);
  });
}
