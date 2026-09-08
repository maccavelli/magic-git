// MADR 0032 Phase 3b: two stores, one reader, one writer.
//
// The split is deliberate and the seam is the target, not the caller: an SSH
// create's namespaces belong to that connection's forge account, a This-Mac
// create's belong to the Mac's own gh/glab login. These tests pin that callers
// never have to know.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/namespace_history.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeStore extends ConnectionStore {
  final List<SavedConnection> updated = [];
  @override
  Future<void> updateMetadata(SavedConnection conn) async => updated.add(conn);
  @override
  Future<void> touch(String id, {DateTime? when}) async {}
}

const _conn = SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/srv/repo',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the key separates forges and hosts', () {
    // A GitLab group is not a GitHub org, and two instances are two accounts.
    expect(
      namespaceHistoryKey(Forge.gitlab, 'a.example'),
      isNot(namespaceHistoryKey(Forge.github, 'a.example')),
    );
    expect(
      namespaceHistoryKey(Forge.gitlab, 'a.example'),
      isNot(namespaceHistoryKey(Forge.gitlab, 'b.example')),
    );
  });

  group('SSH target — history rides the connection', () {
    test('recording writes it back through the store', () async {
      final store = _FakeStore();
      await NamespaceHistory(store).record(
        forge: Forge.gitlab,
        host: 'a.example',
        namespace: 'team/alpha',
        connection: _conn,
      );

      final saved = store.updated.single;
      expect(
        saved.namespacesFor(namespaceHistoryKey(Forge.gitlab, 'a.example')),
        ['team/alpha'],
      );
    });

    test('reads back from the connection, not from prefs', () async {
      final withHistory = _conn.withNamespaceUse(
        namespaceHistoryKey(Forge.gitlab, 'a.example'),
        'team/alpha',
      );
      expect(
        await NamespaceHistory(_FakeStore()).recent(
          forge: Forge.gitlab,
          host: 'a.example',
          connection: withHistory,
        ),
        ['team/alpha'],
      );
    });

    test(
      'the most recent use moves to the front without duplicating',
      () async {
        var conn = _conn;
        const key = 'gitlab@a.example';
        for (final ns in ['one', 'two', 'one']) {
          conn = conn.withNamespaceUse(key, ns);
        }
        expect(conn.namespacesFor(key), ['one', 'two']);
      },
    );

    test('history is bounded', () async {
      var conn = _conn;
      const key = 'gitlab@a.example';
      for (var i = 0; i < SavedConnection.maxNamespaceHistory + 5; i++) {
        conn = conn.withNamespaceUse(key, 'ns$i');
      }
      expect(
        conn.namespacesFor(key),
        hasLength(SavedConnection.maxNamespaceHistory),
      );
      expect(conn.namespacesFor(key).first, 'ns14', reason: 'newest first');
    });

    test('it round-trips through JSON', () async {
      final conn = _conn.withNamespaceUse('gitlab@a.example', 'team/alpha');
      final back = SavedConnection.fromJson(conn.toJson());
      expect(back.namespacesFor('gitlab@a.example'), ['team/alpha']);
    });

    test('a profile with no history round-trips unchanged', () async {
      // The parallel-map contract: absent means "no history", not a migration.
      expect(_conn.toJson().containsKey('namespaceHistory'), isFalse);
      expect(
        SavedConnection.fromJson(_conn.toJson()).namespaceHistory,
        isEmpty,
      );
    });
  });

  group('This Mac — history lives locally', () {
    test('records and reads back with no connection', () async {
      final history = NamespaceHistory(_FakeStore());
      await history.record(
        forge: Forge.github,
        host: 'github.com',
        namespace: 'acme',
      );

      expect(await history.recent(forge: Forge.github, host: 'github.com'), [
        'acme',
      ]);
    });

    test('does not touch the connection store', () async {
      final store = _FakeStore();
      await NamespaceHistory(
        store,
      ).record(forge: Forge.github, host: 'github.com', namespace: 'acme');
      expect(store.updated, isEmpty);
    });

    test('the two stores do not see each other', () async {
      // The whole point of the split: a This-Mac create and an SSH create are
      // different forge accounts even at the same host.
      final store = _FakeStore();
      final history = NamespaceHistory(store);
      await history.record(
        forge: Forge.gitlab,
        host: 'a.example',
        namespace: 'local-only',
      );

      expect(
        await history.recent(
          forge: Forge.gitlab,
          host: 'a.example',
          connection: _conn,
        ),
        isEmpty,
        reason: 'the connection has its own history, and it is empty',
      );
    });
  });
}
