// The Settings rows for MADR 0048: which application opens a file, and which
// opens a terminal.
//
// Unset must read as the system default — that is the behaviour `11f9ed7`
// restored and the one every install starts with. A stored choice must read as
// its NAME: the identifier that actually launches it ("Cursor" is
// `com.todesktop.230313mzl4w4u92`) is unreadable, which is why the name is
// stored beside it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/utils/app_bundle.dart';
import 'package:remote_magic_git/features/settings/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings built directly, so no test waits on an asynchronous prefs read,
/// and every [setPreferredApps] call is recorded.
class _Settings extends AppSettingsNotifier {
  _Settings(this._initial);

  final AppSettings _initial;
  final List<({AppBundle? editor, AppBundle? terminal})> calls = [];

  @override
  AppSettings build() {
    markSettingsLoaded();
    return _initial;
  }

  @override
  Future<void> setPreferredApps({
    AppBundle? editor,
    AppBundle? terminal,
  }) async {
    calls.add((editor: editor, terminal: terminal));
    state = state.copyWith(
      preferredEditorBundleId: editor?.bundleId,
      preferredEditorName: editor?.name,
      preferredTerminalBundleId: terminal?.bundleId,
      preferredTerminalName: terminal?.name,
    );
  }
}

/// InlineActionButton wraps MacosTooltip (not Flutter's Tooltip).
Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

Future<_Settings> _pump(WidgetTester tester, AppSettings initial) async {
  SharedPreferences.setMockInitialValues({});
  final settings = _Settings(initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith(() => settings)],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SettingsSheet(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  testWidgets('the rows read System default and Terminal when nothing is '
      'chosen', (tester) async {
    await _pump(tester, const AppSettings());

    expect(find.text('Open files with'), findsOneWidget);
    expect(find.text('Open terminal with'), findsOneWidget);
    expect(find.text('System default'), findsOneWidget);
    expect(
      find.text('Terminal'),
      findsOneWidget,
      reason: 'macOS has no default terminal, so this is the stated fallback',
    );
  });

  testWidgets('a stored choice is shown by name, not by bundle id', (
    tester,
  ) async {
    await _pump(
      tester,
      const AppSettings(
        preferredEditorBundleId: 'com.todesktop.230313mzl4w4u92',
        preferredEditorName: 'Cursor',
      ),
    );

    expect(find.text('Cursor'), findsOneWidget);
    expect(
      find.text('com.todesktop.230313mzl4w4u92'),
      findsNothing,
      reason: 'the identifier launches it; the name is what a person reads',
    );
    expect(
      find.text('System default'),
      findsNothing,
      reason: 'the editor row now names the choice',
    );
  });

  testWidgets('Reset clears the stored choice', (tester) async {
    final settings = await _pump(
      tester,
      const AppSettings(
        preferredEditorBundleId: 'com.example.editor',
        preferredEditorName: 'Editor',
      ),
    );

    // Two rows carry this tooltip; the terminal's is disabled while unset, so
    // the first enabled one is the editor's.
    final reset = _byMacosTooltip('Use the system default').first;
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(settings.calls, hasLength(1));
    expect(settings.calls.single.editor?.bundleId, isEmpty);
    expect(find.text('System default'), findsOneWidget);
  });
}
