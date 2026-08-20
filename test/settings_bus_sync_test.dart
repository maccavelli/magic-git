// SettingsBus: a settings/keymap write in one tab's container reloads it in
// another (each tab is its own root container with its own notifier), with no
// runaway ping-pong (value-equal reload is a no-op).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a settings write in one tab reloads it in another (no ping-pong)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final a = ProviderContainer();
      final b = ProviderContainer();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      // Build both notifiers so they subscribe to the bus.
      a.read(appSettingsProvider);
      b.read(appSettingsProvider);
      await pumpEventQueue();

      await a
          .read(appSettingsProvider.notifier)
          .setPreferences(committerName: 'Alice');
      await pumpEventQueue();

      expect(
        b.read(appSettingsProvider).committerName,
        'Alice',
        reason: 'the sibling tab reloaded the write',
      );
      // Settles — a value-equal reload triggers no further churn.
      await pumpEventQueue();
      expect(b.read(appSettingsProvider).committerName, 'Alice');
      expect(a.read(appSettingsProvider).committerName, 'Alice');
    },
  );

  test('a keymap rebind in one tab reloads it in another', () async {
    SharedPreferences.setMockInitialValues({});
    final a = ProviderContainer();
    final b = ProviderContainer();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    a.read(keymapProvider);
    b.read(keymapProvider);
    await pumpEventQueue();

    final actionId = kKeymapActions.first.id;
    // Clearing an action's bindings is a persisted override (default is
    // non-empty), so it round-trips to disk and the sibling can read it back.
    await a.read(keymapProvider.notifier).setBindings(actionId, const []);
    await pumpEventQueue();

    expect(
      b.read(keymapProvider)[actionId],
      isEmpty,
      reason: 'the sibling tab reloaded the rebind',
    );
  });
}
