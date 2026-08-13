import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';

void main() {
  const ssh = SavedWorkspaceRepositoryRef(
    kind: SavedRepositoryKind.ssh,
    savedId: 'ssh-1',
    repoPath: '/srv/app',
    tabAlias: 'Backend',
    layoutPresetName: 'review',
  );
  const local = SavedWorkspaceRepositoryRef(
    kind: SavedRepositoryKind.local,
    savedId: 'local-1',
    repoPath: '/Users/me/app',
  );

  test(
    'versioned set round-trips ordered references and clamps active index',
    () {
      const set = SavedWorkspaceSet(
        id: 'set-1',
        displayName: 'Daily work',
        repositories: [ssh, local],
        activeIndex: 9,
      );

      final decoded = SavedWorkspaceSet.fromJson(set.toJson());

      expect(decoded.version, SavedWorkspaceSet.currentVersion);
      expect(decoded.displayName, 'Daily work');
      expect(decoded.repositories, [ssh, local]);
      expect(decoded.activeIndex, 1);
      expect(decoded, set.normalized);
    },
  );

  test('record contains references but no credentials or bookmark bytes', () {
    const set = SavedWorkspaceSet(
      id: 'set-1',
      displayName: 'Daily work',
      repositories: [ssh, local],
      activeIndex: 0,
    );

    final encoded = jsonEncode(set.toJson());

    expect(encoded, isNot(contains('password')));
    expect(encoded, isNot(contains('privateKey')));
    expect(encoded, isNot(contains('token')));
    expect(encoded, isNot(contains('bookmark')));
    expect(encoded, contains('ssh-1'));
    expect(encoded, contains('/Users/me/app'));
  });

  test('unknown version and empty required fields are rejected', () {
    expect(
      () => SavedWorkspaceSet.fromJson({
        'version': 99,
        'id': 'future',
        'displayName': 'Future',
        'repositories': const <Object?>[],
      }),
      throwsFormatException,
    );
    expect(
      () => SavedWorkspaceRepositoryRef.fromJson({
        'kind': 'ssh',
        'savedId': '',
        'repoPath': '/srv/app',
      }),
      throwsFormatException,
    );
  });

  test('unknown optional preset and blank alias normalize away', () {
    final ref = SavedWorkspaceRepositoryRef.fromJson({
      'kind': 'local',
      'savedId': 'local-1',
      'repoPath': '/repo',
      'tabAlias': '   ',
      'layoutPresetName': 'future-preset',
    });

    expect(ref.tabAlias, isNull);
    expect(ref.layoutPresetName, isNull);
  });

  test('stable identity distinguishes backend and path', () {
    expect(
      ssh.identity,
      isNot(
        const SavedWorkspaceRepositoryRef(
          kind: SavedRepositoryKind.local,
          savedId: 'ssh-1',
          repoPath: '/srv/app',
        ).identity,
      ),
    );
    expect(
      ssh.identity,
      isNot(
        const SavedWorkspaceRepositoryRef(
          kind: SavedRepositoryKind.ssh,
          savedId: 'ssh-1',
          repoPath: '/srv/other',
        ).identity,
      ),
    );
  });
}
