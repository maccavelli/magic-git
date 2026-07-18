// Persistence for the scoped work-tree (dotfiles) repo toggle: the external
// git-dir must round-trip through JSON on both saved models, and be absent from
// the JSON for an ordinary repo so pre-existing entries migrate untouched.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';

void main() {
  group('SavedLocalRepo.gitDir', () {
    test('ordinary repo omits gitDir from JSON and is not scoped', () {
      const repo = SavedLocalRepo(id: 'a', label: 'x', repoPath: '/home/u');
      expect(repo.isScoped, isFalse);
      expect(repo.toJson().containsKey('gitDir'), isFalse);
    });

    test('scoped repo round-trips its git-dir', () {
      const repo = SavedLocalRepo(
        id: 'a',
        label: 'dotfiles',
        repoPath: '/home/u',
        gitDir: '/home/u/.home.git',
      );
      expect(repo.isScoped, isTrue);
      final back = SavedLocalRepo.fromJson(repo.toJson());
      expect(back.gitDir, '/home/u/.home.git');
      expect(back.isScoped, isTrue);
      expect(back.repoPath, '/home/u');
    });

    test('legacy JSON without gitDir migrates as an ordinary repo', () {
      final back = SavedLocalRepo.fromJson({
        'id': 'a',
        'label': 'x',
        'repoPath': '/home/u',
      });
      expect(back.gitDir, '');
      expect(back.isScoped, isFalse);
    });

    test('copyWith preserves and updates gitDir', () {
      const repo = SavedLocalRepo(id: 'a', label: 'x', repoPath: '/home/u');
      expect(repo.copyWith(gitDir: '/home/u/.home.git').isScoped, isTrue);
      expect(
        repo.copyWith(label: 'y').gitDir,
        '',
        reason: 'unrelated copyWith must not disturb gitDir',
      );
    });
  });

  group('SavedConnection.scopedGitDirs', () {
    const base = SavedConnection(
      id: 'c',
      label: 'l',
      host: 'h',
      port: 22,
      username: 'u',
      repoPath: '/home/u',
      repoPaths: ['/home/u', '/srv/other'],
    );

    test('ordinary connection omits scopedGitDirs and reports none', () {
      expect(base.scopedGitDirFor('/home/u'), '');
      expect(base.toJson().containsKey('scopedGitDirs'), isFalse);
    });

    test('withScopedGitDir sets and clears per-repo, round-tripping', () {
      final scoped = base.withScopedGitDir('/home/u', '/home/u/.home.git');
      expect(scoped.scopedGitDirFor('/home/u'), '/home/u/.home.git');
      expect(scoped.scopedGitDirFor('/srv/other'), ''); // untouched

      final back = SavedConnection.fromJson(scoped.toJson());
      expect(back.scopedGitDirFor('/home/u'), '/home/u/.home.git');

      // Clearing removes the key entirely (an absent key = ordinary repo).
      final cleared = scoped.withScopedGitDir('/home/u', '');
      expect(cleared.scopedGitDirFor('/home/u'), '');
      expect(cleared.toJson().containsKey('scopedGitDirs'), isFalse);
    });

    test('scopes for other repos survive a re-save of one repo', () {
      final two = base
          .withScopedGitDir('/home/u', '/home/u/.home.git')
          .withScopedGitDir('/srv/other', '/srv/other/.bare');
      final back = SavedConnection.fromJson(two.toJson());
      expect(back.scopedGitDirs.length, 2);
      expect(back.scopedGitDirFor('/srv/other'), '/srv/other/.bare');
    });

    test('malformed scopedGitDirs JSON degrades to empty', () {
      final back = SavedConnection.fromJson({
        'id': 'c',
        'label': 'l',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'repoPath': '/home/u',
        'scopedGitDirs': 'not-a-map',
      });
      expect(back.scopedGitDirs, isEmpty);
    });
  });
}
