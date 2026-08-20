// The Add Worktree sheet's copy-globs and post-create command are persisted, so
// they don't have to be retyped for every worktree. The answer is the same
// nearly every time (`.env*`, `pnpm install`), and that per-worktree friction is
// exactly what makes an otherwise good feature feel like a chore.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('the defaults are useful out of the box', () {
    final settings = container().read(appSettingsProvider);

    // `.env*` on, because a worktree without it is a checkout that will not run
    // — the single most common real-world complaint about `git worktree`.
    expect(settings.worktreeCopyGlobs, '.env*');
    expect(settings.worktreeCopyEnabled, isTrue);
    // A post-create command is project-specific, so nothing is assumed.
    expect(settings.worktreePostCreate, isEmpty);
    expect(settings.worktreePostCreateEnabled, isFalse);
  });

  test('what you used last time comes back next time', () async {
    final c = container();

    await c
        .read(appSettingsProvider.notifier)
        .setWorktreeDefaults(
          copyGlobs: '.env*, .env.local, config/*.local',
          copyEnabled: true,
          postCreate: 'pnpm install',
          postCreateEnabled: true,
        );

    final settings = c.read(appSettingsProvider);
    expect(settings.worktreeCopyGlobs, '.env*, .env.local, config/*.local');
    expect(settings.worktreePostCreate, 'pnpm install');
    expect(settings.worktreePostCreateEnabled, isTrue);
  });

  test('they survive a restart', () async {
    await container()
        .read(appSettingsProvider.notifier)
        .setWorktreeDefaults(
          copyGlobs: '.env.production',
          copyEnabled: false,
          postCreate: 'make setup',
          postCreateEnabled: true,
        );

    // A fresh container is a fresh launch: it starts at defaults and folds in
    // the stored values once the async read lands.
    final fresh = container();
    await fresh.read(appSettingsProvider.notifier).reloadFromDisk();

    final settings = fresh.read(appSettingsProvider);
    expect(settings.worktreeCopyGlobs, '.env.production');
    expect(settings.worktreeCopyEnabled, isFalse);
    expect(settings.worktreePostCreate, 'make setup');
    expect(settings.worktreePostCreateEnabled, isTrue);
  });

  test(
    'a parked post-create command can be disarmed without losing it',
    () async {
      final c = container();
      final notifier = c.read(appSettingsProvider.notifier);

      await notifier.setWorktreeDefaults(
        postCreate: 'pnpm install',
        postCreateEnabled: true,
      );
      // Enabled is a separate flag from the string precisely so the command can be
      // kept around while switched off, rather than having to be retyped later.
      await notifier.setWorktreeDefaults(postCreateEnabled: false);

      expect(c.read(appSettingsProvider).worktreePostCreate, 'pnpm install');
      expect(c.read(appSettingsProvider).worktreePostCreateEnabled, isFalse);
    },
  );
}
