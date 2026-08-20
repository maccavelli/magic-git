import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';

void main() {
  test(
    'decodeIdentities round-trips an unencrypted OpenSSH ed25519 PEM',
    () async {
      if (!File('/usr/bin/ssh-keygen').existsSync()) {
        return;
      }
      final dir = Directory.systemTemp.createTempSync('mg_pem_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/id';
      final r = await Process.run('/usr/bin/ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-C',
        '',
        '-f',
        path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final pem = File(path).readAsStringSync();

      final keys = await SSHClientManager.decodeIdentities(pem, null);
      expect(keys, isNotEmpty);
      final again = SSHKeyPair.fromPem(keys.first.toPem());
      expect(again, isNotEmpty);
      expect(
        again.first.toPublicKey().encode(),
        keys.first.toPublicKey().encode(),
      );
    },
  );

  test(
    'decodeIdentities round-trips a passphrase-protected OpenSSH ed25519 PEM',
    () async {
      if (!File('/usr/bin/ssh-keygen').existsSync()) {
        return;
      }
      final dir = Directory.systemTemp.createTempSync('mg_pem_enc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/id';
      final r = await Process.run('/usr/bin/ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        'test-pass',
        '-C',
        '',
        '-f',
        path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final pem = File(path).readAsStringSync();
      expect(pem, contains('OPENSSH PRIVATE KEY'));

      final keys = await SSHClientManager.decodeIdentities(pem, 'test-pass');
      expect(keys, isNotEmpty);

      // The export is unencrypted: decode happens once off the UI isolate,
      // and the resulting key pairs are handed to all three clients without
      // re-entering the passphrase.
      final again = SSHKeyPair.fromPem(keys.first.toPem());
      expect(again, isNotEmpty);
      expect(
        again.first.toPublicKey().encode(),
        keys.first.toPublicKey().encode(),
      );
    },
  );

  test('decodeIdentities rejects the wrong passphrase', () async {
    if (!File('/usr/bin/ssh-keygen').existsSync()) {
      return;
    }
    final dir = Directory.systemTemp.createTempSync('mg_pem_bad_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/id';
    final r = await Process.run('/usr/bin/ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      'test-pass',
      '-C',
      '',
      '-f',
      path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final pem = File(path).readAsStringSync();

    await expectLater(
      SSHClientManager.decodeIdentities(pem, 'nope'),
      throwsA(isA<SSHKeyDecryptError>()),
    );
  });
}
