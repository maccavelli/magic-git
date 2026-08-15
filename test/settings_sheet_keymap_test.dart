// The Settings sheet's "Keyboard Mappings" section: it summarizes the
// current customization count and its "Customize" InlineActionButton opens
// the KeyboardMappingsSheet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/features/settings/keyboard_mappings_sheet.dart';
import 'package:remote_magic_git/features/settings/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// InlineActionButton wraps MacosTooltip (not Flutter's Tooltip).
Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

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

  testWidgets('workspace appearance controls are visible in Settings', (
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

    final appearance = find.text('Workspace appearance');
    await tester.ensureVisible(appearance);
    await tester.pumpAndSettle();
    expect(appearance, findsOneWidget);
    expect(find.text('Density'), findsOneWidget);
    expect(find.text('High contrast'), findsOneWidget);
    expect(find.textContaining('Reduce Motion'), findsOneWidget);
  });

  // 0009 M28: a custom auto-fetch interval (edited config, older build) must
  // not read as Off — nor be silently coerced to Off by a Save.
  testWidgets('a custom auto-fetch interval survives opening Settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'autoFetchMinutes': 7});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Land the persisted settings BEFORE the sheet mounts — production opens
    // Settings long after launch, when the async load has resolved.
    container.read(appSettingsProvider);
    await tester.runAsync(() async {
      while (container.read(appSettingsProvider).autoFetchMinutes != 7) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SettingsSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Every 7 min'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
  });
}
