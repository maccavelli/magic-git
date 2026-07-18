import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';

void main() {
  group('SavedConnection', () {
    test('round-trips through JSON', () {
      const conn = SavedConnection(
        id: 'abc',
        label: 'Prod',
        host: 'git.example.com',
        port: 2222,
        username: 'deploy',
        repoPath: '/srv/git/app',
      );
      final restored = SavedConnection.fromJson(conn.toJson());
      expect(restored.id, conn.id);
      expect(restored.label, conn.label);
      expect(restored.host, conn.host);
      expect(restored.port, conn.port);
      expect(restored.username, conn.username);
      expect(restored.repoPath, conn.repoPath);
    });

    test('preserves lastConnectedAt through JSON and copyWith', () {
      final when = DateTime.utc(2026, 7, 1, 12, 30);
      final conn = SavedConnection(
        id: 'a',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
        lastConnectedAt: when,
      );
      expect(SavedConnection.fromJson(conn.toJson()).lastConnectedAt, when);
      // copyWith on an unrelated field keeps the timestamp.
      expect(conn.copyWith(repoPath: '/other').lastConnectedAt, when);

      // A never-connected profile omits the key and round-trips as null.
      const never = SavedConnection(
        id: 'b',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      );
      expect(never.toJson().containsKey('lastConnectedAt'), isFalse);
      expect(SavedConnection.fromJson(never.toJson()).lastConnectedAt, isNull);
    });

    test('fromJson tolerates missing fields with sane defaults', () {
      final conn = SavedConnection.fromJson({'host': 'h', 'username': 'u'});
      expect(conn.port, 22);
      expect(conn.label, '');
      expect(conn.repoPath, '');
    });

    test('displayName falls back to user@host when unlabeled', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      );
      expect(conn.displayName, 'u@h');
    });

    test('displayName uses the label when present', () {
      const conn = SavedConnection(
        id: 'x',
        label: 'My Server',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      );
      expect(conn.displayName, 'My Server');
    });

    test('repoPaths round-trip through JSON', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
        repoPaths: ['/a', '/b'],
      );
      final restored = SavedConnection.fromJson(conn.toJson());
      expect(restored.repoPaths, ['/a', '/b']);
    });

    test('allRepoPaths includes repoPath first, deduped', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
        repoPaths: ['/b', '/a'],
      );
      expect(conn.allRepoPaths, ['/a', '/b']);
    });

    test('copyWith updates only the repo fields', () {
      const conn = SavedConnection(
        id: 'x',
        label: 'L',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
      );
      final c2 = conn.copyWith(repoPath: '/c', repoPaths: ['/a', '/c']);
      expect(c2.repoPath, '/c');
      expect(c2.repoPaths, ['/a', '/c']);
      expect(c2.label, 'L');
      expect(c2.host, 'h');
    });

    test('fsmonitorPaths round-trip and per-repo lookup', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
        repoPaths: ['/a', '/b'],
        fsmonitorPaths: ['/a'],
      );
      final restored = SavedConnection.fromJson(conn.toJson());
      expect(restored.fsmonitorPaths, ['/a']);
      expect(restored.fsmonitorEnabledFor('/a'), isTrue);
      expect(restored.fsmonitorEnabledFor('/b'), isFalse);
    });

    test('withFsmonitor toggles a repo on and off without dupes', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
        repoPaths: ['/a', '/b'],
      );
      final on = conn.withFsmonitor('/b', true);
      expect(on.fsmonitorEnabledFor('/b'), isTrue);
      // Enabling an already-enabled repo does not duplicate it.
      expect(on.withFsmonitor('/b', true).fsmonitorPaths, ['/b']);
      final off = on.withFsmonitor('/b', false);
      expect(off.fsmonitorEnabledFor('/b'), isFalse);
      expect(off.fsmonitorPaths, isEmpty);
    });

    test('repoLabels round-trip and drive repoDisplayName', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/srv/git/app',
        repoPaths: ['/srv/git/app', '/srv/git/tools'],
        repoLabels: {'/srv/git/app': 'The App'},
      );
      final restored = SavedConnection.fromJson(conn.toJson());
      expect(restored.repoLabels, {'/srv/git/app': 'The App'});
      expect(restored.repoLabelFor('/srv/git/app'), 'The App');
      // Labeled repo shows its label; unlabeled falls back to the basename.
      expect(restored.repoDisplayName('/srv/git/app'), 'The App');
      expect(restored.repoDisplayName('/srv/git/tools'), 'tools');
    });

    test('withRepoLabel sets and clears without persisting empties', () {
      const conn = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
        repoPaths: ['/a', '/b'],
      );
      final named = conn.withRepoLabel('/b', 'Beta');
      expect(named.repoLabelFor('/b'), 'Beta');
      expect(named.repoDisplayName('/b'), 'Beta');
      // Clearing drops the key entirely (an empty label is never stored).
      final cleared = named.withRepoLabel('/b', '');
      expect(cleared.repoLabels.containsKey('/b'), isFalse);
      expect(cleared.repoDisplayName('/b'), 'b');
      // A blank label passed directly is likewise never persisted.
      expect(conn.withRepoLabel('/a', '').repoLabels, isEmpty);
    });

    test('repoLabels omitted from JSON when empty, absent on old profiles', () {
      const bare = SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/a',
      );
      expect(bare.toJson().containsKey('repoLabels'), isFalse);
      // A profile written before labels existed round-trips to an empty map.
      final old = SavedConnection.fromJson({
        'host': 'h',
        'username': 'u',
        'repoPath': '/a',
      });
      expect(old.repoLabels, isEmpty);
      expect(old.repoDisplayName('/a'), 'a');
    });

    test('fromJson defaults fsmonitor off and migrates the legacy flag', () {
      final fresh = SavedConnection.fromJson({'host': 'h', 'username': 'u'});
      expect(fresh.fsmonitorPaths, isEmpty);

      final legacy = SavedConnection.fromJson({
        'host': 'h',
        'username': 'u',
        'repoPath': '/a',
        'enableFsmonitor': true,
      });
      expect(legacy.fsmonitorPaths, ['/a']);
      expect(legacy.fsmonitorEnabledFor('/a'), isTrue);
    });
  });
}
