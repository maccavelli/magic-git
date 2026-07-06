import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

// In `flutter test` there is no flutter_secure_storage platform implementation,
// so every Keychain call throws — which is exactly the unsigned-build path.
// These tests therefore verify the 0600 dotfile fallback end-to-end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String dotfile;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('rmg_store_test');
    dotfile = '${tmp.path}/creds.json';
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test(
    'secrets round-trip through the dotfile when Keychain is unavailable',
    () async {
      final store = ConnectionStore(dotfilePath: dotfile);
      const conn = SavedConnection(
        id: 'x',
        label: 'Prod',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      );

      await store.save(
        conn,
        secret: 'pw',
        gitlabToken: 'glpat-abc',
        privateKey: 'PEMDATA',
        passphrase: 'pp',
      );

      expect(await store.secretFor('x'), 'pw');
      expect(await store.gitlabTokenFor('x'), 'glpat-abc');
      expect(await store.privateKeyFor('x'), 'PEMDATA');
      expect(await store.passphraseFor('x'), 'pp');

      // Metadata still persisted via shared_preferences.
      final list = await store.list();
      expect(list.single.host, 'h');
    },
  );

  test('dotfile is created with 0600 permissions', () async {
    final store = ConnectionStore(dotfilePath: dotfile);
    await store.save(
      const SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      ),
      secret: 'pw',
    );

    final file = File(dotfile);
    expect(await file.exists(), isTrue);
    // Low 9 bits are the POSIX permission bits; 0600 == 384.
    final perms = (await file.stat()).mode & 0x1FF;
    expect(perms, 0x180); // rw-------
  });

  test('delete removes secrets from the dotfile', () async {
    final store = ConnectionStore(dotfilePath: dotfile);
    await store.save(
      const SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      ),
      secret: 'pw',
    );
    await store.delete('x');
    expect(await store.secretFor('x'), isNull);
  });

  test('empty secrets do not create a dotfile', () async {
    final store = ConnectionStore(dotfilePath: dotfile);
    await store.save(
      const SavedConnection(
        id: 'x',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      ),
      // no secrets
    );
    expect(await File(dotfile).exists(), isFalse);
  });

  test('touch stamps lastConnectedAt and floats the profile to the end', () async {
    final store = ConnectionStore(dotfilePath: dotfile);
    const a = SavedConnection(
      id: 'a',
      label: '',
      host: 'h',
      port: 22,
      username: 'u',
      repoPath: '/r',
    );
    const b = SavedConnection(
      id: 'b',
      label: '',
      host: 'h',
      port: 22,
      username: 'u',
      repoPath: '/r',
    );
    await store.updateMetadata(a);
    await store.updateMetadata(b);

    final when = DateTime.utc(2026, 1, 2, 3, 4);
    await store.touch('a', when: when);

    final list = await store.list();
    expect(list.map((c) => c.id).toList(), ['b', 'a']); // 'a' re-appended last
    expect(list.firstWhere((c) => c.id == 'a').lastConnectedAt, when);
    expect(list.firstWhere((c) => c.id == 'b').lastConnectedAt, isNull);

    // Touching a missing id is a harmless no-op.
    await store.touch('nope');
    expect((await store.list()).length, 2);
  });

  test('a corrupt metadata blob degrades to an empty list', () async {
    SharedPreferences.setMockInitialValues({
      'saved_connections': 'garbage, not json',
    });
    final store = ConnectionStore(dotfilePath: dotfile);
    // Must not throw — list() is read by the landing page and called inside
    // every save/touch/updateMetadata/delete.
    expect(await store.list(), isEmpty);
  });

  test('a malformed connection entry is skipped; valid ones survive', () async {
    SharedPreferences.setMockInitialValues({
      'saved_connections': jsonEncode([
        'not-a-map',
        {
          'id': 'a',
          'label': 'A',
          'host': 'h',
          'port': 22,
          'username': 'u',
          'repoPath': '/r',
        },
      ]),
    });
    final store = ConnectionStore(dotfilePath: dotfile);
    final list = await store.list();
    expect(list.single.id, 'a');
  });

  test(
    'concurrent metadata writes are serialized, not lost to a '
    'read-modify-write race',
    () async {
      final store = ConnectionStore(dotfilePath: dotfile);
      const a = SavedConnection(
        id: 'a',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      );
      const b = SavedConnection(
        id: 'b',
        label: '',
        host: 'h',
        port: 22,
        username: 'u',
        repoPath: '/r',
      );
      await store.updateMetadata(a);
      await store.updateMetadata(b);

      // Fired together, with no await between them: each of save/updateMetadata
      // /touch/delete reads the full list, then writes back a modified copy.
      // Without serializing that read-modify-write, whichever write commits
      // last would silently clobber the other's change with its own
      // stale-read copy of the list.
      final whenA = DateTime.utc(2026, 1, 1);
      await Future.wait([
        store.touch('a', when: whenA),
        store.updateMetadata(b.copyWith(repoPath: '/renamed')),
      ]);

      final list = await store.list();
      expect(list.firstWhere((c) => c.id == 'a').lastConnectedAt, whenA);
      expect(list.firstWhere((c) => c.id == 'b').repoPath, '/renamed');
    },
  );
}
