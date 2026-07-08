// EscapeDismissible: Escape pops a wrapped sheet, whether or not the sheet has
// focusable content — and it does so even when a focused descendant (e.g. a
// selectable diff) would otherwise consume the key, because dismissal is routed
// through the focus-independent EscapeDismissRegistry rather than the focus
// tree. A descendant may still opt to intercept Escape for itself.

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

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
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

    await _escape(tester);
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

    await _escape(tester);
    expect(find.byType(MacosSheet), findsNothing);
  });

  testWidgets('Escape closes the sheet even when a focused descendant consumes '
      'the key via the focus tree', (tester) async {
    // A Focus that reports every Escape as handled models a focused selection
    // field swallowing the key before it can bubble to an ancestor. The
    // registry sees the raw key regardless, so the sheet still closes.
    await _open(
      tester,
      MacosSheet(
        child: SizedBox(
          width: 300,
          height: 160,
          child: Focus(
            autofocus: true,
            onKeyEvent: (_, event) =>
                event.logicalKey == LogicalKeyboardKey.escape
                ? KeyEventResult.handled
                : KeyEventResult.ignored,
            child: const Text('GREEDY'),
          ),
        ),
      ),
    );
    expect(find.text('GREEDY'), findsOneWidget);

    await _escape(tester);
    expect(find.text('GREEDY'), findsNothing);
  });

  testWidgets('a descendant interceptor claims Escape and keeps the sheet open '
      'until it stops intercepting', (tester) async {
    await _open(tester, const MacosSheet(child: _Interceptor()));
    expect(find.byType(_Interceptor), findsOneWidget);

    // While intercepting, Escape is consumed by the descendant — sheet stays.
    await _escape(tester);
    expect(find.byType(_Interceptor), findsOneWidget);
    expect(find.text('caught: 1'), findsOneWidget);

    // Toggle interception off; now Escape dismisses the sheet.
    await tester.tap(find.text('caught: 1'));
    await tester.pumpAndSettle();
    await _escape(tester);
    expect(find.byType(_Interceptor), findsNothing);
  });

  testWidgets('a later-registered popup consumes Escape (LIFO), leaving the '
      'sheet beneath open', (tester) async {
    // Two stacked EscapeDismissible routes: only the frontmost pops per press.
    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (outer) => Center(
            child: PushButton(
              controlSize: ControlSize.large,
              child: const Text('open A'),
              onPressed: () => showMacosSheet<void>(
                context: outer,
                builder: (a) => EscapeDismissible(
                  child: MacosSheet(
                    child: SizedBox(
                      width: 320,
                      height: 200,
                      child: Center(
                        child: PushButton(
                          controlSize: ControlSize.large,
                          child: const Text('open B'),
                          onPressed: () => showMacosSheet<void>(
                            context: a,
                            builder: (_) => const EscapeDismissible(
                              child: MacosSheet(
                                child: SizedBox(
                                  width: 240,
                                  height: 140,
                                  child: Center(child: Text('B BODY')),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open B'));
    await tester.pumpAndSettle();
    expect(find.text('B BODY'), findsOneWidget);

    // First Escape closes only B; A stays.
    await _escape(tester);
    expect(find.text('B BODY'), findsNothing);
    expect(find.text('open B'), findsOneWidget);

    // Second Escape closes A.
    await _escape(tester);
    expect(find.text('open B'), findsNothing);
  });
}

/// Test widget that intercepts Escape while [_intercepting] is true.
class _Interceptor extends StatefulWidget {
  const _Interceptor();
  @override
  State<_Interceptor> createState() => _InterceptorState();
}

class _InterceptorState extends State<_Interceptor> {
  VoidCallback? _disposer;
  bool _intercepting = true;
  int _count = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disposer ??= EscapeInterceptor.of(context, () {
      if (!_intercepting) return false;
      setState(() => _count++);
      return true;
    });
  }

  @override
  void dispose() {
    _disposer?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 160,
      child: Center(
        child: GestureDetector(
          onTap: () => setState(() => _intercepting = false),
          child: Text('caught: $_count'),
        ),
      ),
    );
  }
}
