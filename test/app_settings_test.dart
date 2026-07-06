// Configurable command timeouts: defaults, load-from-prefs, persistence with a
// floor, and injection into gitServiceProvider.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to the built-in timeouts when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final s = c.read(appSettingsProvider);
    expect(s.networkTimeout, GitService.defaultNetworkTimeout);
    expect(s.commitTimeout, GitService.defaultCommitTimeout);
    expect(s.autoFetchMinutes, 5);
  });

  test('loads stored values into state after build', () async {
    SharedPreferences.setMockInitialValues({
      'networkTimeoutSecs': 600,
      'commitTimeoutSecs': 900,
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final loaded = Completer<AppSettings>();
    c.listen(appSettingsProvider, (_, next) {
      if (next.networkTimeout.inSeconds == 600 && !loaded.isCompleted) {
        loaded.complete(next);
      }
    });
    c.read(appSettingsProvider); // build() kicks the async _load

    final s = await loaded.future.timeout(const Duration(seconds: 2));
    expect(s.networkTimeout, const Duration(seconds: 600));
    expect(s.commitTimeout, const Duration(seconds: 900));
  });

  test('setTimeouts persists and clamps to the floor', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    await c.read(appSettingsProvider.notifier).setTimeouts(
      network: const Duration(seconds: 1), // below the 5s floor
      commit: const Duration(seconds: 420),
    );
    final s = c.read(appSettingsProvider);
    expect(s.networkTimeout, const Duration(seconds: 5));
    expect(s.commitTimeout, const Duration(seconds: 420));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('networkTimeoutSecs'), 5);
    expect(prefs.getInt('commitTimeoutSecs'), 420);
  });

  test('setPreferences clamps autoFetchMinutes to a floor and a ceiling', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(appSettingsProvider.notifier);

    await notifier.setPreferences(autoFetchMinutes: -5); // below floor
    expect(c.read(appSettingsProvider).autoFetchMinutes, 0);

    await notifier.setPreferences(autoFetchMinutes: 999999); // above ceiling
    expect(c.read(appSettingsProvider).autoFetchMinutes, 1440);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('autoFetchMinutes'), 1440);
  });

  test(
    'a user edit that lands before _load resolves is not clobbered by the '
    'stale on-disk value',
    () async {
      // Stored value differs from what the user is about to set; the async
      // _load must not overwrite the just-made edit.
      SharedPreferences.setMockInitialValues({'autoFetchMinutes': 30});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // Read triggers build()/_load (fire-and-forget); immediately edit before
      // the async load can resolve.
      c.read(appSettingsProvider);
      await c
          .read(appSettingsProvider.notifier)
          .setPreferences(autoFetchMinutes: 7);

      // Give _load ample time to (wrongly) fire; the edit must survive.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(appSettingsProvider).autoFetchMinutes, 7);
    },
  );

  test(
    'a setting GitService ignores does not rebuild it (avoids an SSH refetch '
    'storm); a setting it consumes does',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final g1 = c.read(gitServiceProvider);
      // autoFetchMinutes is not a GitService input — the provider's select()
      // must not rebuild it, or every settings tweak would re-run status/log/
      // refs/diffs over SSH.
      await c
          .read(appSettingsProvider.notifier)
          .setPreferences(autoFetchMinutes: 10);
      final g2 = c.read(gitServiceProvider);
      expect(identical(g1, g2), isTrue);

      // commitTimeout *is* a GitService input, so it must rebuild.
      await c
          .read(appSettingsProvider.notifier)
          .setTimeouts(commit: const Duration(seconds: 99));
      final g3 = c.read(gitServiceProvider);
      expect(identical(g2, g3), isFalse);
    },
  );

  test('gitServiceProvider adopts the configured timeouts', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(
      c.read(gitServiceProvider).networkTimeout,
      GitService.defaultNetworkTimeout,
    );

    await c
        .read(appSettingsProvider.notifier)
        .setTimeouts(network: const Duration(seconds: 600));

    expect(
      c.read(gitServiceProvider).networkTimeout,
      const Duration(seconds: 600),
    );
  });
}
