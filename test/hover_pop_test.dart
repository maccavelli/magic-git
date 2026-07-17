// The landing-button lift microinteraction (HoverPop): hover pops the control
// up (scale + shadow), pressing dips it below resting scale, releasing springs
// it back, and a disabled control stays inert.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/features/common/hover_pop.dart';

Future<void> _pump(WidgetTester tester, {bool enabled = true}) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: HoverPop(
          enabled: enabled,
          child: GestureDetector(
            onTap: () {},
            child: const SizedBox(width: 200, height: 40, child: Text('GO')),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _scale(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

BoxDecoration _chrome(WidgetTester tester) =>
    tester
            .widget<AnimatedContainer>(
              find.descendant(
                of: find.byType(HoverPop),
                matching: find.byType(AnimatedContainer),
              ),
            )
            .decoration!
        as BoxDecoration;

void main() {
  testWidgets('hover pops the button up (scale + shadow), exit settles it', (
    tester,
  ) async {
    await _pump(tester);
    expect(_scale(tester), 1.0);
    expect(_chrome(tester).boxShadow, isEmpty);

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(tester.getCenter(find.text('GO')));
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.02);
    expect(_chrome(tester).boxShadow, isNotEmpty);

    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
    expect(_chrome(tester).boxShadow, isEmpty);
  });

  testWidgets('pressing dips below resting scale; releasing springs back', (
    tester,
  ) async {
    await _pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('GO')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(_scale(tester), 0.97);
    // Pressed-in state also drops the hover lift shadow.
    expect(_chrome(tester).boxShadow, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    // Pointer is still over the button: it returns to the hover pop.
    expect(_scale(tester), 1.02);
  });

  testWidgets('a disabled control is inert', (tester) async {
    await _pump(tester, enabled: false);

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(tester.getCenter(find.text('GO')));
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
    expect(_chrome(tester).boxShadow, isEmpty);

    await gesture.down(tester.getCenter(find.text('GO')));
    await tester.pump();
    expect(_scale(tester), 1.0);
    await gesture.up();
  });
}
