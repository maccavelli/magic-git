// Escape dismisses the shared alert dialogs (errors, confirms, guardrail
// choices) and the custom overlay menus — surfaces that showMacosAlertDialog /
// OverlayEntry don't dismiss on their own.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/actions.dart';
import 'package:remote_magic_git/features/common/context_menu.dart';

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

/// Pumps a host with a button that runs [onPressed] (which shows a dialog).
Future<BuildContext> _host(
  WidgetTester tester,
  void Function(BuildContext) onPressed,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) {
          captured = context;
          return Center(
            child: PushButton(
              controlSize: ControlSize.large,
              onPressed: () => onPressed(context),
              child: const Text('go'),
            ),
          );
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('Escape closes an error dialog', (tester) async {
    await _host(tester, (context) => showErrorDialog(context, 'boom'));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('boom'), findsOneWidget);

    await _escape(tester);
    expect(find.text('boom'), findsNothing);
  });

  testWidgets('Escape cancels a confirm dialog (returns false)', (tester) async {
    bool? result;
    await _host(tester, (context) async {
      result = await confirmAction(
        context,
        title: 'Delete?',
        message: 'This cannot be undone.',
        confirmLabel: 'Delete',
        destructive: true,
      );
    });
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Delete?'), findsOneWidget);

    await _escape(tester);
    expect(find.text('Delete?'), findsNothing);
    expect(result, isFalse, reason: 'Escape must resolve as a cancel');
  });

  testWidgets('Escape dismisses a guardrail choice (returns null)', (
    tester,
  ) async {
    Object? sentinel = 'unset';
    await _host(tester, (context) async {
      sentinel = await chooseAction<String>(
        context,
        title: 'Uncommitted changes',
        message: 'Switch anyway?',
        primaryLabel: 'Stash & switch',
        primaryValue: 'stash',
        secondary: const [('Switch anyway', 'force')],
      );
    });
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Uncommitted changes'), findsOneWidget);

    await _escape(tester);
    expect(find.text('Uncommitted changes'), findsNothing);
    expect(sentinel, isNull, reason: 'dismiss resolves to null');
  });

  testWidgets('Escape closes a context menu overlay', (tester) async {
    final menu = ContextMenuOverlay();
    addTearDown(menu.dispose);
    late BuildContext ctx;
    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) {
            ctx = context;
            return const Center(child: Text('canvas'));
          },
        ),
      ),
    );

    menu.show(ctx, const Offset(40, 40), [
      ContextMenuItem(icon: CupertinoIcons.doc, label: 'Copy', onTap: () {}),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(menu.isShowing, isTrue);

    await _escape(tester);
    expect(find.text('Copy'), findsNothing);
    expect(menu.isShowing, isFalse);
  });
}
