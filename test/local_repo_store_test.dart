// Persistence coverage for LocalRepoStore, mirroring connection_store_test.dart's
// conventions (round-trip, corrupt-blob-degrades-to-empty, per-entry skip).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/local_repo_store.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('list() is empty with nothing saved', () async {
    final store = LocalRepoStore();
    expect(await store.list(), isEmpty);
  });

  test('save() then list() round-trips a repo', () async {
    final store = LocalRepoStore();
    const repo = SavedLocalRepo(
      id: 'r1',
      label: 'My Repo',
      repoPath: '/Users/sam/dev/myrepo',
      bookmarkData: 'aGVsbG8=',
      fsmonitorEnabled: true,
    );
    await store.save(repo);

    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.id, 'r1');
    expect(list.single.label, 'My Repo');
    expect(list.single.repoPath, '/Users/sam/dev/myrepo');
    expect(list.single.bookmarkData, 'aGVsbG8=');
    expect(list.single.fsmonitorEnabled, isTrue);
  });

  test('displayName falls back to the folder basename', () async {
    const named = SavedLocalRepo(id: '1', label: 'Nice Name', repoPath: '/a/b');
    const unnamed = SavedLocalRepo(id: '2', label: '', repoPath: '/a/b/myrepo');
    expect(named.displayName, 'Nice Name');
    expect(unnamed.displayName, 'myrepo');
  });

  test('save() replaces an existing entry with the same id', () async {
    final store = LocalRepoStore();
    await store.save(
      const SavedLocalRepo(id: 'r1', label: 'First', repoPath: '/a'),
    );
    await store.save(
      const SavedLocalRepo(id: 'r1', label: 'Second', repoPath: '/a'),
    );
    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.label, 'Second');
  });

  test('touch() stamps lastConnectedAt and leaves others unaffected', () async {
    final store = LocalRepoStore();
    await store.save(const SavedLocalRepo(id: 'r1', label: 'A', repoPath: '/a'));
    await store.save(const SavedLocalRepo(id: 'r2', label: 'B', repoPath: '/b'));

    final when = DateTime(2026, 1, 1);
    await store.touch('r1', when: when);

    final list = await store.list();
    final r1 = list.firstWhere((r) => r.id == 'r1');
    final r2 = list.firstWhere((r) => r.id == 'r2');
    expect(r1.lastConnectedAt, when);
    expect(r2.lastConnectedAt, isNull);
  });

  test('touch() on an unknown id is a no-op', () async {
    final store = LocalRepoStore();
    await store.save(const SavedLocalRepo(id: 'r1', label: 'A', repoPath: '/a'));
    await store.touch('does-not-exist');
    expect(await store.list(), hasLength(1));
  });

  test('delete() removes only the matching entry', () async {
    final store = LocalRepoStore();
    await store.save(const SavedLocalRepo(id: 'r1', label: 'A', repoPath: '/a'));
    await store.save(const SavedLocalRepo(id: 'r2', label: 'B', repoPath: '/b'));
    await store.delete('r1');

    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.id, 'r2');
  });

  test('a corrupt stored blob degrades to an empty list', () async {
    SharedPreferences.setMockInitialValues({
      'saved_local_repos': 'not valid json{{{',
    });
    final store = LocalRepoStore();
    expect(await store.list(), isEmpty);
  });

  test('a non-list JSON value degrades to an empty list', () async {
    SharedPreferences.setMockInitialValues({
      'saved_local_repos': '{"not": "a list"}',
    });
    final store = LocalRepoStore();
    expect(await store.list(), isEmpty);
  });

  test('a single malformed entry is skipped, not the whole list', () async {
    SharedPreferences.setMockInitialValues({
      'saved_local_repos':
          '[{"id":"r1","label":"Good","repoPath":"/a"}, 42, {"id":"r2","label":"Also good","repoPath":"/b"}]',
    });
    final store = LocalRepoStore();
    final list = await store.list();
    expect(list.map((r) => r.id), containsAll(['r1', 'r2']));
  });

  test('updateMetadata is equivalent to save (no secrets to distinguish)', () async {
    final store = LocalRepoStore();
    await store.updateMetadata(
      const SavedLocalRepo(id: 'r1', label: 'A', repoPath: '/a'),
    );
    expect(await store.list(), hasLength(1));
  });
}
