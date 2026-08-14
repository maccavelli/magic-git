@Tags(['integration'])
library;

// Transport paths that only a REAL sshd can exercise.
//
// ACTION_PLAN admitted four of these were untestable without one. This closes
// the honest subset and says plainly which it does NOT close:
//
//   * malformed UTF-8 decode ............ covered here
//   * unified open+drain timeout ........ DRAIN half covered; the
//     open-still-pending branch is not reachable against a real sshd (it opens
//     channels instantly), and stays the stalled-ServerSocket fake's job in
//     ssh_transport_hardening_test.dart
//   * auth-handshake timeout ............ NOT covered; real sshd answers
//     promptly. Same fake owns it.
//   * pending-close on disconnect ....... authenticated variant covered here;
//     the stalled-handshake variant is already covered by that fake.
//
// Deliberately in test/ rather than integration_test/: dartssh2 is pure Dart
// and the executor needs no Flutter engine, so this runs under plain
// `flutter test` in seconds and skips the code-signing/entitlements wall that
// `-d macos` runs hit.
//
// Skips itself (rather than failing) when sshd is unavailable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A throwaway sshd on loopback, owned entirely by this test run.
class _DisposableSshd {
  _DisposableSshd(this.dir, this.port, this._process, this.privateKeyPem);

  final Directory dir;
  final int port;
  final Process _process;
  final String privateKeyPem;

  static const sshdPath = '/usr/sbin/sshd';

  static bool get available =>
      File(sshdPath).existsSync() && File('/usr/bin/ssh-keygen').existsSync();

  static Future<_DisposableSshd?> start() async {
    final dir = Directory.systemTemp.createTempSync('sshd_live_');
    final path = dir.resolveSymbolicLinksSync();

    Future<bool> keygen(String name) async {
      final r = await Process.run('/usr/bin/ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-f',
        '$path/$name',
        '-N',
        '',
      ]);
      return r.exitCode == 0;
    }

    if (!await keygen('hostkey') || !await keygen('id')) {
      dir.deleteSync(recursive: true);
      return null;
    }
    File('$path/authorized_keys').writeAsStringSync(
      File('$path/id.pub').readAsStringSync(),
    );
    await Process.run('/bin/chmod', ['600', '$path/authorized_keys']);

    // sshd cannot bind port 0, so reserve one and hand it over. The gap is a
    // tolerable TOCTOU for a loopback test.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    // StrictModes off is load-bearing: the temp dir's ancestors under
    // /private/tmp are group-writable, which sshd otherwise refuses.
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
''');

    final process = await Process.start(sshdPath, [
      '-f',
      '$path/sshd_config',
      '-D',
      '-e',
    ]);

    // Wait for the listener rather than sleeping a fixed time.
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        s.destroy();
        return _DisposableSshd(
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
    // dartssh2 wants PEM text, not a path.
    privateKey: privateKeyPem,
  );

  Future<void> stop() async {
    // OpenSSH >= 9.8 re-execs /usr/libexec/sshd-session, so kill the whole
    // group — a single PID kill leaves the child holding the port and
    // `flutter test` then hangs on it.
    try {
      Process.killPid(_process.pid, ProcessSignal.sigterm);
    } catch (_) {}
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  _DisposableSshd? sshd;
  late SSHClientManager manager;
  late SSHCommandExecutor executor;
  late Directory repoDir;
  late String repo;

  setUpAll(() async {
    if (!_DisposableSshd.available) {
      sshd = null;
      return;
    }
    sshd = await _DisposableSshd.start();
  });

  tearDownAll(() async => sshd?.stop());

  setUp(() async {
    if (sshd == null) return;
    manager = SSHClientManager();
    executor = SSHCommandExecutor(manager);
    await manager.connect(sshd!.profile, onVerifyHostKey: (_, _) => true);

    repoDir = Directory.systemTemp.createTempSync('sshd_repo_');
    repo = '${repoDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    Future<void> git(List<String> args) async {
      final r = await Process.run('git', args, workingDirectory: repo);
      expect(r.exitCode, 0, reason: 'setup git ${args.join(' ')}: ${r.stderr}');
    }

    await git(['init', '-q', '-b', 'main']);
    await git(['config', 'user.name', 'T']);
    await git(['config', 'user.email', 't@t']);
    await git(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    if (sshd == null) return;
    await manager.disconnect();
    repoDir.deleteSync(recursive: true);
  });

  bool skip() => sshd == null;

  test('malformed UTF-8 in command output decodes to replacement characters '
      'rather than throwing', () async {
    if (skip()) return;

    // Genuinely invalid UTF-8 written as raw bytes, then read back over the
    // wire. Before allowMalformed this threw out of the drain and leaked the
    // session — and no fake could produce it, because the bytes have to
    // survive a real transport to matter.
    File('$repo/bad.bin').writeAsBytesSync([
      0xff,
      0xfe,
      0x80,
      ...'bad'.codeUnits,
    ]);

    final result = await executor.execute(
      repoPath: repo,
      gitArgs: ['cat', 'bad.bin'],
      lane: ExecLane.read,
    );

    expect(result.exitCode, 0);
    expect(result.stdout, contains('bad'));
    expect(
      result.stdout.codeUnits,
      contains(0xFFFD),
      reason: 'the invalid bytes must become U+FFFD, not blow up the decode',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a command that outruns its timeout is killed, not left running',
      () async {
    if (skip()) return;

    await expectLater(
      executor.execute(
        repoPath: repo,
        gitArgs: ['sleep', '30'],
        timeout: const Duration(milliseconds: 400),
        lane: ExecLane.read,
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );

    // The transport must still be usable: the timeout kills the remote process
    // and closes that session only.
    final after = await executor.execute(
      repoPath: repo,
      gitArgs: ['echo', 'still-alive'],
      lane: ExecLane.read,
    );
    expect(after.stdout.trim(), 'still-alive');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('GitService drives a real repo over SSH — the shell escaping and env '
      'prelude hold against a real POSIX shell', () async {
    if (skip()) return;

    // A path with a space and a quote is exactly what ShellEscaper exists for.
    final awkward = '$repo/a file\'s name.txt';
    File(awkward).writeAsStringSync('hello\n');

    final git = GitService(executor);
    final status = await git.status(repo);

    expect(status.isClean, isFalse);
    expect(
      status.untracked.map((f) => f.path),
      contains("a file's name.txt"),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a compressed read round-trips through gzip', () async {
    if (skip()) return;

    // Large enough that compression actually engages.
    final payload = List.filled(500, 'the quick brown fox').join(' ');
    File('$repo/big.txt').writeAsStringSync(payload);

    final result = await executor.execute(
      repoPath: repo,
      gitArgs: ['cat', 'big.txt'],
      lane: ExecLane.read,
      compress: true,
    );

    expect(result.stdout.trim(), payload);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('disconnect while a command is in flight supersedes it and leaves no '
      'pending client', () async {
    if (skip()) return;

    var settled = false;
    final inFlight = executor
        .execute(
          repoPath: repo,
          gitArgs: ['sleep', '10'],
          timeout: const Duration(seconds: 30),
          lane: ExecLane.read,
        )
        .then((_) => settled = true, onError: (_) => settled = true);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await manager.disconnect();

    // The property is that it RESOLVES — success or failure both fine. The
    // bug this guards is a hang: a superseded command whose session was torn
    // out from under it must not leave its future parked forever. This is the
    // authenticated counterpart of the stalled-handshake case the
    // ServerSocket fake covers.
    await inFlight.timeout(
      const Duration(seconds: 15),
      onTimeout: () =>
          fail('an in-flight command never resolved after disconnect'),
    );
    expect(settled, isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the local executor and the SSH executor agree on the same repo',
      () async {
    if (skip()) return;

    // The executor seam's whole promise: a feature written against one backend
    // behaves the same on the other.
    final viaSsh = await GitService(executor).status(repo);
    final viaLocal = await GitService(LocalCommandExecutor()).status(repo);

    expect(viaSsh.branch.head, viaLocal.branch.head);
    expect(
      viaSsh.files.map((f) => f.path).toSet(),
      viaLocal.files.map((f) => f.path).toSet(),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
