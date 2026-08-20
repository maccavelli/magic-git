// Smoke coverage for the shared forge-sheet atoms. They are used by every
// create/edit sheet (PR, MR, issue, inline creates), so a regression here is
// multiplied across the Forge tab — yet only ForgeMilestonePicker had a test.
//
// One build path each plus the state that actually matters: the submit row's
// in-flight lockout, which is what stops a cancelled submit from orphaning a
// PR that the remote still creates.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/forge/forge_create_sheet_widgets.dart';

import 'helpers/app_scope.dart';

/// [settle] is false wherever a ProgressCircle is on screen: its animation
/// never settles, so pumpAndSettle would time out.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    appProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(width: 600, height: 400, child: child),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Unmounts the tree so a spinner's ticker cannot fail the pending-timer
/// assertion at teardown.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('ForgeSheetField shows its label and reports edits', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'initial');
    addTearDown(controller.dispose);
    var edits = 0;

    await _pump(
      tester,
      ForgeSheetField('Title', controller, onChanged: () => edits++),
    );

    expect(find.text('Title'), findsOneWidget);
    expect(find.text('initial'), findsOneWidget);

    await tester.enterText(find.byType(MacosTextField), 'renamed');
    await tester.pumpAndSettle();

    expect(controller.text, 'renamed');
    expect(edits, greaterThan(0));
  });

  testWidgets('ForgeSheetToggle reports the flipped value', (tester) async {
    bool? received;

    await _pump(
      tester,
      ForgeSheetToggle(
        'Create as draft',
        false,
        onChanged: (v) => received = v,
      ),
    );

    expect(find.text('Create as draft'), findsOneWidget);
    await tester.tap(find.byType(MacosSwitch));
    await tester.pumpAndSettle();

    expect(received, isTrue);
  });

  testWidgets('FieldErrorNote renders its message', (tester) async {
    await _pump(tester, const FieldErrorNote('Title is required'));
    expect(find.text('Title is required'), findsOneWidget);
  });

  testWidgets('SheetSubmitRow gates submit on canSubmit', (tester) async {
    var submits = 0;

    await _pump(
      tester,
      SheetSubmitRow(
        submitting: false,
        canSubmit: false,
        onSubmit: () => submits++,
        submitLabel: 'Create',
      ),
    );

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(submits, 0, reason: 'an invalid form must not submit');
  });

  testWidgets('SheetSubmitRow locks out cancel while submitting', (
    tester,
  ) async {
    var cancels = 0;

    await _pump(
      tester,
      SheetSubmitRow(
        submitting: true,
        canSubmit: true,
        onSubmit: () {},
        onCancel: () => cancels++,
      ),
      settle: false,
    );

    // While a submit is in flight Create is replaced by a spinner and Cancel
    // is disabled — cancelling then would orphan a PR the remote still makes.
    expect(find.byType(ProgressCircle), findsOneWidget);
    expect(find.text('Create'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(cancels, 0);

    await _unmount(tester);
  });

  testWidgets('SheetSubmitRow submits once enabled', (tester) async {
    var submits = 0;

    await _pump(
      tester,
      SheetSubmitRow(
        submitting: false,
        canSubmit: true,
        onSubmit: () => submits++,
        submitLabel: 'Create merge request',
      ),
    );

    await tester.tap(find.text('Create merge request'));
    await tester.pumpAndSettle();
    expect(submits, 1);
  });

  testWidgets('ForgeDiffPreview hints instead of fetching on empty branches', (
    tester,
  ) async {
    await _pump(
      tester,
      const ForgeDiffPreview(
        repoPath: '/srv/repo',
        from: '',
        into: 'main',
        emptyHint: 'Set head and base branches to preview.',
      ),
    );

    // An empty branch pair must not reach the executor: a `git diff ...` with
    // a blank ref is a remote round trip that can only fail.
    // The hint lives behind the collapsed preview toggle.
    expect(find.text('Preview changes'), findsOneWidget);
    await tester.tap(find.text('Preview changes'));
    await tester.pumpAndSettle();

    // An empty branch pair must not reach the executor: a `git diff ...` with
    // a blank ref is a remote round trip that can only fail.
    expect(
      find.textContaining('Set head and base branches to preview.'),
      findsOneWidget,
    );
  });
}
