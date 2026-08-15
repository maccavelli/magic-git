// 0009 H8: the docked CommitComposer is the production commit surface — the
// advertised commit chords (⌘↩ / ⇧⌘↩ by default) must fire there, exactly as
// they do on the sheet-hosted CommitDialog, including while the message field
// has focus.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/repository/commit_composer.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';

CommitComposerController _controller() {
  final controller = CommitComposerController(
    repoPath: '/repo',
    generatePreview: () async => null,
    loadGpgSignConfigured: () async => false,
    loadRecentSubjects: () async => const <String>[],
    loadTemplate: () async => null,
  );
  controller.updateStaged(count: 2, signature: 'a');
  return controller;
}

Future<List<bool>> _pump(
  WidgetTester tester,
  CommitComposerController controller,
) async {
  final accepted = <bool>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        home: SizedBox(
          width: 800,
          height: 420,
          child: CommitComposer(
            controller: controller,
            presentation: CommitComposerPresentation.expanded,
            branchLabel: 'main',
            onAccept: (push) async => accepted.add(push),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return accepted;
}

void main() {
  testWidgets('⌘↩ commits and ⇧⌘↩ commits-and-pushes from the message field', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    final accepted = await _pump(tester, controller);

    // Type a message so canAccept is true, leaving focus in the field —
    // exactly the state a user commits from.
    await tester.enterText(find.byType(MacosTextField), 'feat: something');
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(accepted, [false]);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(accepted, [false, true]);
  });

  testWidgets('the chords are inert while the draft cannot be accepted', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    final accepted = await _pump(tester, controller);

    // No message typed → canAccept is false → the chord must do nothing.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(accepted, isEmpty);
  });
}
