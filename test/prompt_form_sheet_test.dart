// The reusable multi-field sheet (promptForm): multi-field prefill + return,
// and live validation gating the confirm button.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/prompt_form_sheet.dart';

List<PromptField> _fields() => [
  PromptField(
    key: 'title',
    label: 'Title',
    initial: 'Old title',
    validate: (v) => v.isEmpty ? 'Required.' : null,
  ),
  const PromptField(
    key: 'body',
    label: 'Body',
    initial: 'Old body',
    multiline: true,
  ),
];

void main() {
  testWidgets('returns the trimmed values keyed by field', (tester) async {
    Map<String, String>? result;
    await tester.pumpWidget(
      MacosApp(
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () async {
                result = await promptForm(context, 'Edit item', fields: _fields());
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Body'), findsOneWidget);

    // Two fields only (no list filter here): first = title, last = body.
    await tester.enterText(find.byType(MacosTextField).last, '  New body  ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Values are trimmed; the untouched title comes back unchanged.
    expect(result, {'title': 'Old title', 'body': 'New body'});
  });

  testWidgets('disables Save while a required field is empty', (tester) async {
    Map<String, String>? result;
    var returned = false;
    await tester.pumpWidget(
      MacosApp(
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () async {
                result = await promptForm(context, 'Edit item', fields: _fields());
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Empty the required title → its error shows and Save goes inert.
    await tester.enterText(find.byType(MacosTextField).first, '');
    await tester.pumpAndSettle();
    expect(find.text('Required.'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(returned, isFalse, reason: 'Save disabled → the sheet stays open');

    // Restore a title → Save works and returns both fields.
    await tester.enterText(find.byType(MacosTextField).first, 'Restored');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, {'title': 'Restored', 'body': 'Old body'});
  });
}
