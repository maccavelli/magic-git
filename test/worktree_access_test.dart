// WorktreeAccess.forget: when a worktree is removed or moved away, its
// panel-minted saved-grant entry must be deleted (otherwise dead
// "Local Repositories" rows accumulate in the Connections panel) — while a
// repo the user saved themselves at the same path is left alone.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/worktrees/worktree_access.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  test(
    'forget deletes the panel-minted entry, keeps a user-saved one',
    () async {
      final store = container.read(localRepoStoreProvider);
      // The grant record the Worktrees panel mints (mainRepoPath set → linked).
      await store.save(
        const SavedLocalRepo(
          id: 'wt-1',
          label: '',
          repoPath: '/code/app-feature',
          bookmarkData: 'bm',
          mainRepoPath: '/code/app',
        ),
      );
      // A repo the user saved themselves at the SAME path — not ours to delete.
      await store.save(
        const SavedLocalRepo(
          id: 'user-1',
          label: 'mine',
          repoPath: '/code/app-feature',
          bookmarkData: 'bm',
        ),
      );
      // An unrelated worktree entry that must survive.
      await store.save(
        const SavedLocalRepo(
          id: 'wt-2',
          label: '',
          repoPath: '/code/app-other',
          bookmarkData: 'bm',
          mainRepoPath: '/code/app',
        ),
      );

      await container.read(worktreeAccessProvider).forget('/code/app-feature');

      final left = (await store.list()).map((r) => r.id).toSet();
      expect(left, {'user-1', 'wt-2'});
    },
  );

  test('forget with no matching entry is a harmless no-op', () async {
    await container.read(worktreeAccessProvider).forget('/nowhere');
    expect(await container.read(localRepoStoreProvider).list(), isEmpty);
  });
}
