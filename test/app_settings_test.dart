// Configurable command timeouts: defaults, load-from-prefs, persistence with a
// floor, and injection into gitServiceProvider.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/pane_layout.dart';
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

  test('setPaneWidth clamps to the spec bounds and persists per-id keys', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(appSettingsProvider.notifier);

    await notifier.setPaneWidth(PaneId.historyList, 10000); // above ceiling
    expect(c.read(appSettingsProvider).paneWidth(PaneId.historyList), 800);
    await notifier.setPaneWidth(PaneId.jobsList, 10); // below floor
    expect(c.read(appSettingsProvider).paneWidth(PaneId.jobsList), 180);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_historyList'), 800);
    expect(prefs.getDouble('paneWidth_jobsList'), 180);
  });

  test('pane widths load from disk with clamping, fall back to spec defaults, '
      'and load never writes back', () async {
    SharedPreferences.setMockInitialValues({
      'paneWidth_stashList': 9999.0, // out of range on disk
      'paneWidth_forgeList': 400.0,
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final loaded = Completer<AppSettings>();
    c.listen(appSettingsProvider, (_, next) {
      if (next.paneWidthOrNull(PaneId.forgeList) == 400 &&
          !loaded.isCompleted) {
        loaded.complete(next);
      }
    });
    c.read(appSettingsProvider);
    final s = await loaded.future.timeout(const Duration(seconds: 2));

    expect(s.paneWidth(PaneId.stashList), 640, reason: 'clamped to spec.max');
    expect(s.paneWidth(PaneId.forgeList), 400);
    expect(s.paneWidth(PaneId.historyList), 420, reason: 'spec default');
    expect(s.paneWidthOrNull(PaneId.historyList), isNull);

    // Sanitized in state only — the stored value is not rewritten.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_stashList'), 9999.0);
  });

  test('setPaneWidth early-returns when the clamped value is unchanged, but '
      'the first explicit reset-to-default still persists', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(appSettingsProvider.notifier);

    var changes = 0;
    c.listen(appSettingsProvider, (_, _) => changes++);

    // No entry stored: an explicit set to the DEFAULT width must persist
    // (the raw-map-entry comparison, not the defaulted getter).
    await notifier.setPaneWidth(PaneId.historyList, 420);
    expect(changes, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_historyList'), 420);

    // Same value again — clamped result equals the stored entry: no churn.
    await notifier.setPaneWidth(PaneId.historyList, 420);
    expect(changes, 1);
    // Beyond the ceiling while already pinned there: still no churn.
    await notifier.setPaneWidth(PaneId.historyList, 800);
    expect(changes, 2);
    await notifier.setPaneWidth(PaneId.historyList, 12345);
    expect(changes, 2);
  });

  test('reloadFromDisk re-landing equal pane widths is a state no-op', () async {
    SharedPreferences.setMockInitialValues({'paneWidth_historyList': 500.0});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final loaded = Completer<void>();
    c.listen(appSettingsProvider, (_, next) {
      if (next.paneWidthOrNull(PaneId.historyList) == 500 &&
          !loaded.isCompleted) {
        loaded.complete();
      }
    });
    c.read(appSettingsProvider);
    await loaded.future.timeout(const Duration(seconds: 2));

    // A cross-isolate 'settingsChanged' that re-reads identical disk state
    // must not emit — the map field participates in value equality, which is
    // what terminates the sync echo between windows.
    var changes = 0;
    c.listen(appSettingsProvider, (_, _) => changes++);
    await c.read(appSettingsProvider.notifier).reloadFromDisk();
    expect(changes, 0);
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

  test('setHistoryAllBranches updates state and persists setting', () async {
    SharedPreferences.setMockInitialValues({'historyAllBranches': true});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(appSettingsProvider).historyAllBranches, isTrue);

    await c.read(appSettingsProvider.notifier).setHistoryAllBranches(false);
    expect(c.read(appSettingsProvider).historyAllBranches, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('historyAllBranches'), isFalse);
  });
}
