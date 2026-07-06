import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/known_hosts_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('lookup returns null for a host never remembered', () async {
    final store = KnownHostsStore();
    expect(await store.lookup('example.com', 22), isNull);
  });

  test('remember then lookup round-trips the entry', () async {
    final store = KnownHostsStore();
    await store.remember(
      'example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:abc'),
    );
    final entry = await store.lookup('example.com', 22);
    expect(entry!.keyType, 'ssh-ed25519');
    expect(entry.fingerprint, 'SHA256:abc');
  });

  test('different ports on the same host are tracked independently', () async {
    final store = KnownHostsStore();
    await store.remember(
      'example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:aaa'),
    );
    await store.remember(
      'example.com',
      2222,
      const KnownHostEntry(keyType: 'ssh-rsa', fingerprint: 'SHA256:bbb'),
    );
    expect((await store.lookup('example.com', 22))!.fingerprint, 'SHA256:aaa');
    expect(
      (await store.lookup('example.com', 2222))!.fingerprint,
      'SHA256:bbb',
    );
  });

  test('remember overwrites a previous entry for the same host:port', () async {
    final store = KnownHostsStore();
    await store.remember(
      'example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-rsa', fingerprint: 'SHA256:old'),
    );
    await store.remember(
      'example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:new'),
    );
    final entry = await store.lookup('example.com', 22);
    expect(entry!.keyType, 'ssh-ed25519');
    expect(entry.fingerprint, 'SHA256:new');
  });

  test('forget drops the entry, reverting to trust-on-first-use', () async {
    final store = KnownHostsStore();
    await store.remember(
      'example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:abc'),
    );
    await store.forget('example.com', 22);
    expect(await store.lookup('example.com', 22), isNull);
  });

  test('forget on an unknown host is a harmless no-op', () async {
    final store = KnownHostsStore();
    await store.forget('example.com', 22);
    expect(await store.lookup('example.com', 22), isNull);
  });

  test(
    'a corrupt blob is treated as empty rather than throwing — a throw here '
    'runs inside onVerifyHostKey and would block connecting to every host',
    () async {
      SharedPreferences.setMockInitialValues({
        'known_hosts': 'not valid json {{{',
      });
      final store = KnownHostsStore();
      // Degrades to trust-on-first-use instead of throwing.
      expect(await store.lookup('example.com', 22), isNull);
      // And the store still works afterward.
      await store.remember(
        'example.com',
        22,
        const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:new'),
      );
      expect((await store.lookup('example.com', 22))!.fingerprint, 'SHA256:new');
    },
  );

  test('malformed entries are skipped; valid ones still load', () async {
    SharedPreferences.setMockInitialValues({
      'known_hosts': jsonEncode({
        '[bad.example.com]:22': 'not-a-map',
        '[partial.example.com]:22': {'keyType': 'ssh-ed25519'}, // no fingerprint
        '[good.example.com]:22': {
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:ok',
        },
      }),
    });
    final store = KnownHostsStore();
    expect(await store.lookup('bad.example.com', 22), isNull);
    expect(await store.lookup('partial.example.com', 22), isNull);
    expect((await store.lookup('good.example.com', 22))!.fingerprint, 'SHA256:ok');
  });

  test(
    'concurrent remembers for different hosts are serialized, not lost to a '
    'read-modify-write race',
    () async {
      final store = KnownHostsStore();
      await Future.wait([
        store.remember(
          'a.example.com',
          22,
          const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:a'),
        ),
        store.remember(
          'b.example.com',
          22,
          const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:b'),
        ),
      ]);
      expect((await store.lookup('a.example.com', 22))!.fingerprint, 'SHA256:a');
      expect((await store.lookup('b.example.com', 22))!.fingerprint, 'SHA256:b');
    },
  );

  test(
    'an IPv6-literal host with colons does not collide with another '
    'host:port pair',
    () async {
      final store = KnownHostsStore();
      await store.remember(
        '::1',
        22,
        const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:v6'),
      );
      await store.remember(
        'fe80::1',
        2222,
        const KnownHostEntry(keyType: 'ssh-rsa', fingerprint: 'SHA256:other'),
      );
      expect((await store.lookup('::1', 22))!.fingerprint, 'SHA256:v6');
      expect(
        (await store.lookup('fe80::1', 2222))!.fingerprint,
        'SHA256:other',
      );
    },
  );

  test('list enumerates every remembered host, sorted by host then port', () async {
    final store = KnownHostsStore();
    await store.remember(
      'b.example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:b'),
    );
    await store.remember(
      'a.example.com',
      2222,
      const KnownHostEntry(keyType: 'ssh-rsa', fingerprint: 'SHA256:a2'),
    );
    await store.remember(
      'a.example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:a1'),
    );

    final list = await store.list();
    expect(
      list.map((r) => '${r.host}:${r.port}').toList(),
      ['a.example.com:22', 'a.example.com:2222', 'b.example.com:22'],
    );
    expect(list[0].entry.fingerprint, 'SHA256:a1');
  });

  test('list omits an entry after it is forgotten', () async {
    final store = KnownHostsStore();
    await store.remember(
      'example.com',
      22,
      const KnownHostEntry(keyType: 'ssh-ed25519', fingerprint: 'SHA256:abc'),
    );
    await store.forget('example.com', 22);
    expect(await store.list(), isEmpty);
  });
}
