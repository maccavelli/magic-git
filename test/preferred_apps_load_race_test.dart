import 'dart:io';

// A launch must act on the user's stored choice, not on whatever has loaded so
// far.
//
// `AppSettingsNotifier.build()` returns defaults and reads disk
// fire-and-forget, and every tab is its own container with its own load. The
// launch paths ("Open file", "Open in Terminal") therefore cannot read `state`
// at click time: the first read in a freshly built tab returns defaults, and
// the launch falls through to the system default — which is how Open in
// Terminal opened Terminal.app with WezTerm chosen (plan 0048 deviation (b)).
//
// They read `loaded` instead, which waits for that first load.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
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
    expect(apps.preferredTerminalBundleId, isEmpty);
  });

  test(
    'a launch reads the stored choice on a container it just created',
    () async {
      SharedPreferences.setMockInitialValues({
        'preferredEditorBundleId': 'com.apple.TextEdit',
        'preferredEditorName': 'TextEdit',
        'preferredTerminalBundleId': 'com.github.wez.wezterm',
        'preferredTerminalName': 'WezTerm',
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // No pump, no delay: exactly what a click on a freshly built tab does.
      final apps = await container.read(appSettingsProvider.notifier).loaded;

      expect(
        apps.preferredTerminalBundleId,
        'com.github.wez.wezterm',
        reason: 'reading state directly here returns the empty default',
      );
      expect(apps.preferredEditorBundleId, 'com.apple.TextEdit');
    },
  );

  test('a later read still sees the stored choice', () async {
    SharedPreferences.setMockInitialValues({
      'preferredTerminalBundleId': 'com.github.wez.wezterm',
      'preferredTerminalName': 'WezTerm',
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.notifier).loaded;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(appSettingsProvider).preferredTerminalBundleId,
      'com.github.wez.wezterm',
    );
  });

  // The widget-level test cannot reproduce this race — pumping settles the
  // load before any tap — so the shape is enforced structurally instead, the
  // way `provider_retry_policy_test.dart` enforces its own rule.
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
