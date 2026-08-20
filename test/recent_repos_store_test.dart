// RecentReposStore: the per-repo MRU log. Records move a repo to the front,
// collapse a prior entry for the same repo, keep local/remote identities
// distinct, and cap total history.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/recent_repos_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('records newest-first', () async {
    final store = RecentReposStore();
    await store.record(isLocal: false, id: 'host', repoPath: '/a');
    await store.record(isLocal: true, id: 'mg', repoPath: '/Users/me/mg');

    final list = await store.list();
    expect(list.map((e) => e.id).toList(), ['mg', 'host']);
    expect(list.first.isLocal, isTrue);
  });

  test(
    're-opening a repo moves it to the front and collapses the old entry',
    () async {
      final store = RecentReposStore();
      await store.record(isLocal: false, id: 'host', repoPath: '/a');
      await store.record(isLocal: false, id: 'host', repoPath: '/b');
      await store.record(
        isLocal: false,
        id: 'host',
        repoPath: '/a',
      ); // reopen /a

      final list = await store.list();
      // /a jumps ahead of /b, and there's still only one /a entry.
      expect(list.map((e) => e.repoPath).toList(), ['/a', '/b']);
    },
  );

  test('local and remote with the same id are distinct identities', () async {
    final store = RecentReposStore();
    await store.record(isLocal: false, id: 'x', repoPath: '/p');
    await store.record(isLocal: true, id: 'x', repoPath: '/p');

    final list = await store.list();
    expect(list, hasLength(2));
  });

  test(
    'a repo on the same connection but a different path is its own entry',
    () async {
      final store = RecentReposStore();
      await store.record(isLocal: false, id: 'host', repoPath: '/a');
      await store.record(isLocal: false, id: 'host', repoPath: '/b');

      expect(await store.list(), hasLength(2));
    },
  );

  test('history is capped', () async {
    final store = RecentReposStore();
    for (var i = 0; i < 40; i++) {
      await store.record(isLocal: false, id: 'host', repoPath: '/r$i');
    }
    final list = await store.list();
    expect(list.length, lessThanOrEqualTo(30));
    // The most recent survive; the oldest are trimmed.
    expect(list.first.repoPath, '/r39');
  });

  test('empty and blank ids/paths are ignored', () async {
    final store = RecentReposStore();
    await store.record(isLocal: false, id: '', repoPath: '/a');
    await store.record(isLocal: false, id: 'host', repoPath: '');
    expect(await store.list(), isEmpty);
  });
}
