// A launch must act on the user's stored choice, not on whatever has loaded so
// far, and the load must not throw that choice away.
//
// `AppSettingsNotifier.build()` returns defaults and reads disk
// fire-and-forget, and every tab is its own container with its own load. So
// "Open file" cannot read `state` at click time: the first read in a freshly
// built tab returns defaults and the launch silently uses the system default
// (plan 0048 deviation (b)). It reads `loaded` instead.
//
// And the load itself used to abort on a sticky "any setter ran" flag,
// discarding the WHOLE stored snapshot — one pane-width write moments after a
// tab mounted left that tab on defaults for every setting (deviation (c)).

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/pane_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // FIRST, deliberately: SharedPreferences caches its instance per isolate, so
  // this case only exists before any other test installs mock values.
  test('readiness completes even when storage is unavailable', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final apps = await container
        .read(appSettingsProvider.notifier)
        .loaded
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('a launch would wait forever for storage'),
        );

    expect(apps.preferredEditorBundleId, isEmpty);
  });

  test(
    'a launch reads the stored choice on a container it just created',
    () async {
      SharedPreferences.setMockInitialValues({
        'preferredEditorBundleId': 'com.apple.TextEdit',
        'preferredEditorName': 'TextEdit',
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // No pump, no delay: exactly what a click on a freshly built tab does.
      final apps = await container.read(appSettingsProvider.notifier).loaded;

      expect(
        apps.preferredEditorBundleId,
        'com.apple.TextEdit',
        reason: 'reading state directly here returns the empty default',
      );
      expect(apps.preferredEditorName, 'TextEdit');
    },
  );

  test('an early local write does not discard the stored settings', () async {
    SharedPreferences.setMockInitialValues({
      'preferredEditorBundleId': 'com.apple.TextEdit',
      'preferredEditorName': 'TextEdit',
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(appSettingsProvider.notifier);

    // Exactly what a workspace does moments after a tab mounts.
    await notifier.setPaneWidth(PaneId.filesTree, 300);

    final apps = await notifier.loaded;
    expect(apps.preferredEditorBundleId, 'com.apple.TextEdit');
    expect(
      apps.paneWidth(PaneId.filesTree),
      300,
      reason: 'and the edit that raced the load is still there',
    );
  });

  // The widget-level test cannot reproduce the click-time race — pumping
  // settles the load before any tap — so the shape is enforced structurally,
  // the way `provider_retry_policy_test.dart` enforces its own rule.
  test('no launch path reads a preferred application from state', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final squashed = entity.readAsStringSync().replaceAll(RegExp(r'\s+'), '');
      if (squashed.contains('read(appSettingsProvider).preferred')) {
        offenders.add(entity.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'read(appSettingsProvider).preferred… returns the empty default until '
          'that container has finished its first disk load, so a launch can use '
          'the system default while the user has chosen otherwise. Read '
          'appSettingsProvider.notifier.loaded instead.',
    );
  });
}
