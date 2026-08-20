// Smoke coverage for the merge options sheet: it is the last confirmation
// before an irreversible forge mutation, and until now nothing pumped it.
// One build path (method list, delete-source, buttons) plus the two exits
// (Cancel → null, Merge → the chosen options).
//
// Driven through showMergeOptionsSheet rather than the body widget, because
// the body is private — and the sheet function is what both forge panels
// actually call.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/features/forge/merge_options_sheet.dart';

const _plan = MergePlan(
  canMergeNow: true,
  canEnableAutoMerge: false,
  blockedReasons: [],
  allowedMethods: [MergeMethod.mergeCommit, MergeMethod.squash],
  defaultMethod: MergeMethod.mergeCommit,
  defaultDeleteSource: false,
  pinHeadSha: false,
);

/// Pumps a host page and opens the sheet from it, returning the future the
/// caller would await.
Future<Future<MergeOptionsResult?>> _open(
  WidgetTester tester, {
  MergePlan plan = _plan,
  bool showCommitMessages = true,
}) async {
  await tester.pumpWidget(
    const MacosApp(debugShowCheckedModeBanner: false, home: SizedBox.expand()),
  );
  final context = tester.element(find.byType(SizedBox).first);
  final result = showMergeOptionsSheet(
    context,
    plan: plan,
    title: 'Merge !42',
    summary: 'feature → main',
    showCommitMessages: showCommitMessages,
  );
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('renders the allowed methods, delete-source and both exits', (
    tester,
  ) async {
    final result = await _open(tester);

    expect(find.text('Merge !42'), findsOneWidget);
    expect(find.text('feature → main'), findsOneWidget);
    expect(find.text('Merge method'), findsOneWidget);
    // Only the methods the plan allows — a rebase-forbidden repo must not
    // offer rebase.
    expect(
      find.text(mergeMethodLabel(MergeMethod.mergeCommit)),
      findsOneWidget,
    );
    expect(find.text(mergeMethodLabel(MergeMethod.squash)), findsOneWidget);
    expect(find.text(mergeMethodLabel(MergeMethod.rebase)), findsNothing);
    expect(find.text('Delete source branch after merge'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('Merge returns the selected method and delete-source', (
    tester,
  ) async {
    final result = await _open(tester);

    // Tap the label, not the glyph: that is the behaviour under test.
    await tester.tap(find.text(mergeMethodLabel(MergeMethod.squash)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MacosCheckbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();

    final options = await result;
    expect(options, isNotNull);
    expect(options!.method, MergeMethod.squash);
    expect(options.deleteSource, isTrue);
  });

  testWidgets('the commit-message fields can be suppressed', (tester) async {
    final result = await _open(tester, showCommitMessages: false);

    // A squash-only GitLab MR has no commit-message step; the sheet must not
    // render empty fields the caller will ignore.
    expect(find.byType(MacosTextField), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await result;
  });
}
