// The Settings sheet's "Keyboard Mappings" section: it summarizes the
// current customization count and its "Customize" InlineActionButton opens
// the KeyboardMappingsSheet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/features/settings/keyboard_mappings_sheet.dart';
import 'package:remote_magic_git/features/settings/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// InlineActionButton wraps MacosTooltip (not Flutter's Tooltip).
Finder _byMacosTooltip(String message) => find.byWidgetPredicate(
  (w) => w is MacosTooltip && w.message == message,
);

void main() {
  testWidgets('Customize icon opens the Keyboard Mappings sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: SettingsSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Keyboard Mappings'), findsOneWidget);
    expect(find.textContaining('shortcuts'), findsWidgets);

    // The sheet's content exceeds the default test viewport height and
    // scrolls — bring the button into view before tapping it.
    final customize = _byMacosTooltip('Customize keyboard mappings');
    await tester.ensureVisible(customize);
    await tester.pumpAndSettle();
    await tester.tap(customize);
    await tester.pumpAndSettle();

    expect(find.byType(KeyboardMappingsSheet), findsOneWidget);
  });
}
