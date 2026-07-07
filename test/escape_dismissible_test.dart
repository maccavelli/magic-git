// EscapeDismissible: Escape pops a wrapped sheet, whether or not the sheet has
// focusable content — and it never steals focus from a sheet's autofocused
// field.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/escape_dismissible.dart';

Future<void> _open(WidgetTester tester, Widget sheetChild) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Center(
          child: PushButton(
            controlSize: ControlSize.large,
            child: const Text('open'),
            onPressed: () => showMacosSheet<void>(
              context: context,
              builder: (_) => EscapeDismissible(child: sheetChild),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Escape closes a display-only sheet (no focusable content)', (
    tester,
  ) async {
    await _open(
      tester,
      const MacosSheet(
        child: SizedBox(width: 300, height: 200, child: Text('SHEET BODY')),
      ),
    );
    expect(find.text('SHEET BODY'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('SHEET BODY'), findsNothing);
  });

  testWidgets('Escape closes a sheet that has a text field, and the field '
      'keeps its autofocus', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _open(
      tester,
      MacosSheet(
        child: SizedBox(
          width: 300,
          height: 160,
          child: MacosTextField(controller: controller, autofocus: true),
        ),
      ),
    );

    // The field, not the dismiss node, holds focus.
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MacosSheet), findsNothing);
  });
}
