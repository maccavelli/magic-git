// The read-only Keyboard Shortcuts cheat sheet renders a section per category
// and a chip showing each action's current binding, straight from the keymap.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/settings/keyboard_shortcuts_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('lists category sections and current bindings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: KeyboardShortcutsSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Top-of-list content is on screen: a known action + its binding chip.
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('⌘R'), findsOneWidget);

    // The new categories live further down the (lazily-built) list — scrolling
    // to one proves they render their own section.
    await tester.scrollUntilVisible(
      find.text('File Viewer'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('File Viewer'), findsOneWidget);
    expect(find.text('Close viewer window'), findsOneWidget);
  });
}
