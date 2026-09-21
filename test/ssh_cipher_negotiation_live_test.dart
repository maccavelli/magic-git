@Tags(['integration'])
library;

// Which packet cipher a real connect negotiates — asserted on the wire, from
// the server's own log, not from our configuration.
//
// Why it matters: dartssh2 is pure Dart and decrypts on the isolate that owns
// the socket. Its AES-GCM runs on pointycastle's GCM, whose GHASH is a
// bit-serial loop (128 shift/xor rounds per 16-byte block), and measured about
// 1.2 MiB/s on an idle M1 Pro — against about 30 MiB/s for
// chacha20-poly1305@openssh.com through the same library. dartssh2 3.1.0 made
// AES-GCM its first default, so leaving the defaults alone made every bulk
// read ~25x slower and CPU-bound. A consumer that slow is also slower than
// the socket, and dart:io keeps re-reading a socket that still has bytes
// available in a microtask chain, so for the whole transfer no timer fires —
// the health monitor's, a command timeout's, or a test's own Timeout.
//
// A timing assertion would flake; the negotiated algorithm does not. sshd
// logs it at DEBUG1 ("kex: client->server cipher: …"), so this reads that.
//
// Skips itself (rather than failing) when sshd is unavailable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _sshdPath = '/usr/sbin/sshd';
const _keygenPath = '/usr/bin/ssh-keygen';

/// A throwaway loopback sshd whose DEBUG1 log lands in [logFile].
class _LoggingSshd {
  _LoggingSshd(this._dir, this.port, this._process, this.privateKeyPem);

  final Directory _dir;
  final int port;
  final Process _process;
  final String privateKeyPem;

  File get logFile => File('${_dir.path}/sshd.log');

  static bool get available =>
      File(_sshdPath).existsSync() && File(_keygenPath).existsSync();

  static Future<_LoggingSshd?> start() async {
    final dir = Directory(
      Directory.systemTemp
          .createTempSync('sshd_cipher_')
          .resolveSymbolicLinksSync(),
    );
    final path = dir.path;
    for (final name in ['hostkey', 'id']) {
      final r = await Process.run(_keygenPath, [
        '-q',
        '-t',
        'ed25519',
        '-f',
        '$path/$name',
        '-N',
        '',
      ]);
      if (r.exitCode != 0) {
        dir.deleteSync(recursive: true);
        return null;
      }
    }
    File(
      '$path/authorized_keys',
    ).writeAsStringSync(File('$path/id.pub').readAsStringSync());
    await Process.run('/bin/chmod', ['600', '$path/authorized_keys']);

    final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserve.port;
    await reserve.close();

    // No Ciphers line: the server offers OpenSSH's full default set, so what
    // gets negotiated is decided by the client's preference order alone.
    File('$path/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey $path/hostkey
PidFile $path/sshd.pid
AuthorizedKeysFile $path/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
LogLevel DEBUG1
''');

    // -E sends the log to a file rather than stderr, so an unread stderr pipe
    // can never fill and stall sshd under DEBUG1's volume.
    final process = await Process.start(_sshdPath, [
      '-f',
      '$path/sshd_config',
      '-D',
      '-E',
      '$path/sshd.log',
    ]);
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        s.destroy();
        return _LoggingSshd(
          dir,
          port,
          process,
          File('$path/id').readAsStringSync(),
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    process.kill(ProcessSignal.sigkill);
    dir.deleteSync(recursive: true);
    return null;
  }

  SSHConnectionProfile get profile => SSHConnectionProfile(
    host: '127.0.0.1',
    port: port,
    username: Platform.environment['USER'] ?? 'runner',
    privateKey: privateKeyPem,
  );

  /// Every `kex: <direction> cipher: <name>` line sshd has logged so far.
  List<String> negotiatedCiphers() {
    final pattern = RegExp(
      r'kex: (?:client->server|server->client) cipher: (\S+)',
    );
    return [
      for (final m in pattern.allMatches(logFile.readAsStringSync()))
        m.group(1)!,
    ];
  }

  Future<void> stop() async {
    try {
      Process.killPid(_process.pid, ProcessSignal.sigterm);
    } catch (_) {}
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  _LoggingSshd? sshd;

  setUpAll(() async {
    if (_LoggingSshd.available) sshd = await _LoggingSshd.start();
  });

  tearDownAll(() async => sshd?.stop());

  test('every client of a real connect negotiates '
      'chacha20-poly1305@openssh.com, not the bit-serial AES-GCM', () async {
    final server = sshd;
    if (server == null) return;
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager);
    addTearDown(manager.disconnect);
    await manager.connect(server.profile, onVerifyHostKey: (_, _) => true);

    // One round trip, so the session is demonstrably usable, not just keyed.
    final echo = await executor.execute(
      repoPath: '/',
      gitArgs: const ['echo', 'ok'],
      lane: ExecLane.read,
    );
    expect(echo.stdout.trim(), 'ok');

    final ciphers = server.negotiatedCiphers();
    // Two lines per connection (one per direction). An empty list means the
    // log did not say, which must fail loudly rather than pass vacuously.
    expect(
      ciphers.length,
      greaterThanOrEqualTo(2 * manager.attachedClientCount),
      reason:
          'sshd logged too few kex lines:\n'
          '${server.logFile.readAsStringSync()}',
    );
    expect(ciphers, everyElement('chacha20-poly1305@openssh.com'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
