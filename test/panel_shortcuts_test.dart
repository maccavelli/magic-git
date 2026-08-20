import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';

void main() {
  testWidgets('fires bindings when no text interaction has focus', (
    tester,
  ) async {
    var fired = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: PanelShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.backspace,
                meta: true,
              ): () =>
                  fired++,
            },
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(fired, 1);
  });

  testWidgets(
    '⌘⌫ inside a text field edits text instead of firing the panel binding',
    (tester) async {
      var fired = 0;
      final controller = TextEditingController(text: 'feature/wip');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Material(
              child: PanelShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.backspace,
                    meta: true,
                  ): () =>
                      fired++,
                },
                child: TextField(controller: controller),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      // Caret to end, then ⌘⌫ = macOS delete-to-line-start.
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(fired, 0, reason: 'panel binding must yield to text editing');
      expect(
        controller.text,
        isEmpty,
        reason: 'the edit key reached the field',
      );
    },
    // ⌘⌫ = delete-to-line-start only exists in the macOS/iOS text-editing
    // shortcut tables; the guard itself is platform-independent.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('bare-key bindings yield while a text field is focused', (
    tester,
  ) async {
    var toggled = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: PanelShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.space): () =>
                    toggled++,
              },
              child: TextField(controller: controller),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(toggled, 0);
  });

  testWidgets('⌘C yields while a SelectionArea holds focus', (tester) async {
    var copiedSha = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: PanelShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.keyC,
                  meta: true,
                ): () =>
                    copiedSha++,
              },
              child: SelectionArea(
                focusNode: node,
                child: const Text('diff line'),
              ),
            ),
          ),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    expect(PanelShortcuts.textInteractionHasFocus(), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(copiedSha, 0, reason: '⌘C must stay Copy for the selection');
  });

  testWidgets('bindings resume once focus leaves the field', (tester) async {
    var fired = 0;
    final controller = TextEditingController();
    final elsewhere = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(elsewhere.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: PanelShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.keyC,
                  meta: true,
                ): () =>
                    fired++,
              },
              child: Column(
                children: [
                  TextField(controller: controller),
                  Focus(
                    focusNode: elsewhere,
                    child: const SizedBox(height: 10),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(fired, 0);

    elsewhere.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(fired, 1);
  });
}
