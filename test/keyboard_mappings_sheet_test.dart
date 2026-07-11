// Covers the Customize Keyboard Mappings sheet: replacing a binding by
// recording a real key combo, adding a second binding without dropping the
// first, resetting back to default, and cancelling a recording with Esc.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/features/settings/keyboard_mappings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MacosTooltip (not Flutter's Tooltip) exposes its message as a plain field,
/// so `find.byTooltip` doesn't see it — match on the wrapper widget instead.
Finder _byMacosTooltip(String message) => find.byWidgetPredicate(
  (w) => w is MacosTooltip && w.message == message,
);

Future<ProviderContainer> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: KeyboardMappingsSheet(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Narrows the visible rows to just "Refresh" so its chips are unambiguous
/// and guaranteed on-screen without scrolling.
Future<void> _filterToRefresh(WidgetTester tester) async {
  await tester.enterText(find.byType(MacosTextField), 'Refresh');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('clicking a binding chip replaces it with the recorded combo', (
    tester,
  ) async {
    final container = await _pump(tester);
    await _filterToRefresh(tester);

    expect(find.text('⌘R'), findsOneWidget);

    await tester.tap(find.text('⌘R'));
    await tester.pump();
    expect(find.text('Press keys…'), findsOneWidget);

    // ⌘J: not a default binding of any action (⌘Z is global.undo's now, and
    // recording a taken combo triggers the conflict dialog instead).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('⌘J'), findsOneWidget);
    expect(find.text('⌘R'), findsNothing);
    expect(
      container.read(keymapProvider)['global.refresh'],
      [KeyBinding.fromKey(LogicalKeyboardKey.keyJ, meta: true)],
    );
  });

  testWidgets('+ Add binds a second trigger without dropping the first', (
    tester,
  ) async {
    final container = await _pump(tester);
    await _filterToRefresh(tester);

    await tester.tap(find.text('+ Add'));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('⌘R'), findsOneWidget);
    expect(find.text('⌃⌥Q'), findsOneWidget);
    expect(container.read(keymapProvider)['global.refresh']!.length, 2);
  });

  testWidgets('reset restores the action to its single default binding', (
    tester,
  ) async {
    final container = await _pump(tester);
    await _filterToRefresh(tester);

    await tester.tap(find.text('⌘R'));
    await tester.pump();
    // ⌘J — see above: a combo no action's defaults claim.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('⌘J'), findsOneWidget);

    await tester.tap(_byMacosTooltip('Reset to default'));
    await tester.pumpAndSettle();

    expect(find.text('⌘R'), findsOneWidget);
    expect(find.text('⌘J'), findsNothing);
    expect(
      container.read(keymapProvider)['global.refresh'],
      kKeymapActionsById['global.refresh']!.defaultBindings,
    );
  });

  testWidgets('Esc cancels an in-progress recording, leaving the binding untouched', (
    tester,
  ) async {
    final container = await _pump(tester);
    await _filterToRefresh(tester);

    await tester.tap(find.text('⌘R'));
    await tester.pump();
    expect(find.text('Press keys…'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('⌘R'), findsOneWidget);
    expect(
      container.read(keymapProvider)['global.refresh'],
      kKeymapActionsById['global.refresh']!.defaultBindings,
    );
  });
}
