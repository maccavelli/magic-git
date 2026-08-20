import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';

void main() {
  group('constructor defaults', () {
    test('defaults bookmark/fsmonitor/worktree fields', () {
      const r = SavedLocalRepo(
        id: 'a',
        label: 'My Repo',
        repoPath: '/home/x/p',
      );
      expect(r.bookmarkData, '');
      expect(r.mainRepoPath, '');
      expect(r.mainRepoBookmarkData, '');
      expect(r.fsmonitorEnabled, isFalse);
      expect(r.gitDir, '');
      expect(r.lastConnectedAt, isNull);
    });

    test('all fields are set when provided', () {
      final dt = DateTime(2026, 7, 1);
      final r = SavedLocalRepo(
        id: 'b',
        label: 'Dotfiles',
        repoPath: '/home/x',
        bookmarkData: 'AQAA...',
        mainRepoPath: '/main',
        mainRepoBookmarkData: 'BQAA...',
        fsmonitorEnabled: true,
        gitDir: '/home/x/.home.git',
        lastConnectedAt: dt,
      );
      expect(r.id, 'b');
      expect(r.label, 'Dotfiles');
      expect(r.repoPath, '/home/x');
      expect(r.bookmarkData, 'AQAA...');
      expect(r.mainRepoPath, '/main');
      expect(r.mainRepoBookmarkData, 'BQAA...');
      expect(r.fsmonitorEnabled, isTrue);
      expect(r.gitDir, '/home/x/.home.git');
      expect(r.lastConnectedAt, dt);
    });
  });

  group('isLinkedWorktree', () {
    test('true when mainRepoPath is non-empty', () {
      const r = SavedLocalRepo(
        id: 'a',
        label: '',
        repoPath: '/w',
        mainRepoPath: '/main',
      );
      expect(r.isLinkedWorktree, isTrue);
    });

    test('false when mainRepoPath is empty', () {
      const r = SavedLocalRepo(id: 'a', label: '', repoPath: '/w');
      expect(r.isLinkedWorktree, isFalse);
    });
  });

  group('isScoped', () {
    test('true when gitDir is non-empty', () {
      const r = SavedLocalRepo(
        id: 'a',
        label: '',
        repoPath: '/home/x',
        gitDir: '/home/x/.home.git',
      );
      expect(r.isScoped, isTrue);
    });

    test('false when gitDir is empty', () {
      const r = SavedLocalRepo(id: 'a', label: '', repoPath: '/home/x');
      expect(r.isScoped, isFalse);
    });
  });

  group('toJson / fromJson round-trip', () {
    SavedLocalRepo roundTrip(SavedLocalRepo r) =>
        SavedLocalRepo.fromJson(r.toJson());

    test('basic repo survives round-trip', () {
      const r = SavedLocalRepo(id: '1', label: 'Work', repoPath: '/code/proj');
      final restored = roundTrip(r);
      expect(restored.id, r.id);
      expect(restored.label, r.label);
      expect(restored.repoPath, r.repoPath);
      expect(restored.fsmonitorEnabled, r.fsmonitorEnabled);
    });

    test('full-featured repo survives round-trip', () {
      final r = SavedLocalRepo(
        id: '2',
        label: 'Dotfiles',
        repoPath: '/home/x',
        bookmarkData: 'AAAA',
        mainRepoPath: '/main',
        mainRepoBookmarkData: 'BBBB',
        fsmonitorEnabled: true,
        gitDir: '/home/x/.home.git',
        lastConnectedAt: DateTime(2026, 7, 25),
      );
      final restored = roundTrip(r);
      expect(restored.id, '2');
      expect(restored.label, 'Dotfiles');
      expect(restored.repoPath, '/home/x');
      expect(restored.bookmarkData, 'AAAA');
      expect(restored.mainRepoPath, '/main');
      expect(restored.mainRepoBookmarkData, 'BBBB');
      expect(restored.fsmonitorEnabled, isTrue);
      expect(restored.gitDir, '/home/x/.home.git');
      expect(restored.lastConnectedAt, DateTime(2026, 7, 25));
    });

    test('null lastConnectedAt is omitted from JSON and stays null', () {
      const r = SavedLocalRepo(id: '3', label: '', repoPath: '/p');
      final json = r.toJson();
      expect(json.containsKey('lastConnectedAt'), isFalse);
      final restored = roundTrip(r);
      expect(restored.lastConnectedAt, isNull);
    });
  });

  group('fromJson migration', () {
    test('missing optional fields default gracefully', () {
      final json = <String, dynamic>{'id': 'x', 'repoPath': '/p'};
      final r = SavedLocalRepo.fromJson(json);
      expect(r.id, 'x');
      expect(r.label, '');
      expect(r.repoPath, '/p');
      expect(r.bookmarkData, '');
      expect(r.mainRepoPath, '');
      expect(r.fsmonitorEnabled, isFalse);
      expect(r.gitDir, '');
      expect(r.lastConnectedAt, isNull);
    });

    test('unknown key in JSON is ignored', () {
      final json = <String, dynamic>{
        'id': 'y',
        'label': 'R',
        'repoPath': '/r',
        'unknown_key': 'ignored',
      };
      final r = SavedLocalRepo.fromJson(json);
      expect(r.repoPath, '/r');
    });

    test('null values in JSON are treated as missing', () {
      final json = <String, dynamic>{
        'id': 'z',
        'label': null,
        'repoPath': '/z',
        'fsmonitorEnabled': null,
      };
      final r = SavedLocalRepo.fromJson(json);
      expect(r.label, '');
      expect(r.fsmonitorEnabled, isFalse);
    });

    test('invalid date string yields null lastConnectedAt', () {
      final json = <String, dynamic>{
        'id': 'w',
        'repoPath': '/w',
        'lastConnectedAt': 'not-a-date',
      };
      final r = SavedLocalRepo.fromJson(json);
      expect(r.lastConnectedAt, isNull);
    });
  });

  group('copyWith', () {
    test('partial update keeps unchanged fields', () {
      const r = SavedLocalRepo(
        id: 'a',
        label: 'L',
        repoPath: '/p',
        fsmonitorEnabled: true,
        gitDir: '/p/.git',
      );
      final updated = r.copyWith(label: 'New Label');
      expect(updated.id, 'a');
      expect(updated.label, 'New Label');
      expect(updated.repoPath, '/p');
      expect(updated.fsmonitorEnabled, isTrue);
      expect(updated.gitDir, '/p/.git');
    });

    test('no args copies all fields identically', () {
      const r = SavedLocalRepo(id: 'a', label: 'L', repoPath: '/p');
      final c = r.copyWith();
      expect(c.id, r.id);
      expect(c.label, r.label);
      expect(c.repoPath, r.repoPath);
      expect(c.fsmonitorEnabled, r.fsmonitorEnabled);
    });
  });

  group('displayName', () {
    test('uses label when non-empty', () {
      const r = SavedLocalRepo(
        id: 'a',
        label: 'My Repo',
        repoPath: '/some/long/path',
      );
      expect(r.displayName, 'My Repo');
    });

    test('falls back to basename of repoPath when label is empty', () {
      const r = SavedLocalRepo(
        id: 'a',
        label: '',
        repoPath: '/home/user/project',
      );
      expect(r.displayName, 'project');
    });
  });

  group('_basename', () {
    test('returns last path component', () {
      // Accessible through displayName
      const r = SavedLocalRepo(id: 'a', label: '', repoPath: '/a/b/c');
      expect(r.displayName, 'c');
    });

    test('handles trailing slash', () {
      const r = SavedLocalRepo(id: 'a', label: '', repoPath: '/a/b/c/');
      expect(r.displayName, 'c');
    });

    test('returns path itself when no slashes', () {
      const r = SavedLocalRepo(id: 'a', label: '', repoPath: 'justadir');
      expect(r.displayName, 'justadir');
    });

    test('root path returns the root itself', () {
      const r = SavedLocalRepo(id: 'a', label: '', repoPath: '/');
      expect(r.displayName, '/');
    });
  });
}
