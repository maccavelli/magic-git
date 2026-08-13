import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const a = SavedWorkspaceRepositoryRef(
    kind: SavedRepositoryKind.ssh,
    savedId: 'ssh-a',
    repoPath: '/a',
  );
  const b = SavedWorkspaceRepositoryRef(
    kind: SavedRepositoryKind.local,
    savedId: 'local-b',
    repoPath: '/b',
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'save, replace, list, and delete preserve deterministic order',
    () async {
      final store = SavedWorkspaceStore();
      const first = SavedWorkspaceSet(
        id: 'one',
        displayName: 'One',
        repositories: [a],
        activeIndex: 0,
      );
      const second = SavedWorkspaceSet(
        id: 'two',
        displayName: 'Two',
        repositories: [b],
        activeIndex: 0,
      );

      await store.save(first);
      await store.save(second);
      await store.save(
        const SavedWorkspaceSet(
          id: 'one',
          displayName: 'One renamed',
          repositories: [a, b],
          activeIndex: 1,
        ),
      );

      expect((await store.list()).map((set) => set.id), ['two', 'one']);
      expect((await store.list()).last.displayName, 'One renamed');
      await store.delete('two');
      expect((await store.list()).map((set) => set.id), ['one']);
    },
  );

  test(
    'corrupt and future records are skipped without losing valid records',
    () async {
      SharedPreferences.setMockInitialValues({
        SavedWorkspaceStore.setsStorageKey: jsonEncode([
          {
            'version': 99,
            'id': 'future',
            'displayName': 'Future',
            'repositories': const <Object?>[],
          },
          'broken',
          {
            'version': 1,
            'id': 42,
            'displayName': 'Malformed',
            'repositories': const <Object?>[],
          },
          const SavedWorkspaceSet(
            id: 'valid',
            displayName: 'Valid',
            repositories: [a],
            activeIndex: 0,
          ).toJson(),
        ]),
      });

      expect((await SavedWorkspaceStore().list()).map((set) => set.id), [
        'valid',
      ]);
    },
  );

  test(
    'aliases persist by stable repository identity and clear cleanly',
    () async {
      final store = SavedWorkspaceStore();

      await store.setAlias(a.identity, 'Backend');
      await store.setAlias(b.identity, 'Frontend');
      expect(await store.aliases(), {
        a.identity: 'Backend',
        b.identity: 'Frontend',
      });

      await store.setAlias(a.identity, '  ');
      expect(await store.aliases(), {b.identity: 'Frontend'});
    },
  );

  test('concurrent set and alias updates do not clobber siblings', () async {
    final store = SavedWorkspaceStore();
    await Future.wait([
      store.save(
        const SavedWorkspaceSet(
          id: 'one',
          displayName: 'One',
          repositories: [a],
          activeIndex: 0,
        ),
      ),
      store.save(
        const SavedWorkspaceSet(
          id: 'two',
          displayName: 'Two',
          repositories: [b],
          activeIndex: 0,
        ),
      ),
      store.setAlias(a.identity, 'A'),
      store.setAlias(b.identity, 'B'),
    ]);

    expect((await store.list()).map((set) => set.id).toSet(), {'one', 'two'});
    expect(await store.aliases(), {a.identity: 'A', b.identity: 'B'});
  });
}
