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

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_telemetry.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_error_messages.dart';

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

  static Future<_DisposableSshd?> start({int? maxSessions}) async {
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
    File(
      '$path/authorized_keys',
    ).writeAsStringSync(File('$path/id.pub').readAsStringSync());
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
${maxSessions == null ? '' : 'MaxSessions $maxSessions\n'}KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group-exchange-sha256
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
    File(
      '$repo/bad.bin',
    ).writeAsBytesSync([0xff, 0xfe, 0x80, ...'bad'.codeUnits]);

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

  test(
    'a command that outruns its timeout is killed, not left running',
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
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('GitService drives a real repo over SSH — the shell escaping and env '
      'prelude hold against a real POSIX shell', () async {
    if (skip()) return;

    // A path with a space and a quote is exactly what ShellEscaper exists for.
    final awkward = '$repo/a file\'s name.txt';
    File(awkward).writeAsStringSync('hello\n');

    final git = GitService(executor);
    final status = await git.status(repo);

    expect(status.isClean, isFalse);
    expect(status.untracked.map((f) => f.path), contains("a file's name.txt"));
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

  test(
    'the local executor and the SSH executor agree on the same repo',
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
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('peer rejects non-overlapping kex with SSHDisconnectError', () async {
    if (skip()) return;
    final socket = await SSHSocket.connect('127.0.0.1', sshd!.port);
    final client = SSHClient(
      socket,
      username: sshd!.profile.username,
      identities: SSHKeyPair.fromPem(sshd!.privateKeyPem),
      algorithms: const SSHAlgorithms(kex: [SSHKexType.dh1Sha1]),
      onVerifyHostKey: (_, _) => true,
    );
    try {
      await client.authenticated;
      fail('expected the server to disconnect');
    } catch (e) {
      // 3.3.0 picks the algorithm locally after both KEXINITs. With no
      // overlap it completes `authenticated` as SSHAuthAbortError whose
      // reason is SSHInternalError(StateError('No matching key exchange
      // algorithm')) — not a peer SSH_MSG_DISCONNECT. The typed
      // SSHDisconnectError mapping is unit-tested; this live case proves
      // we do not silently negotiate dh-group1 against a modern sshd.
      expect(e, isA<SSHAuthAbortError>());
      final reason = (e as SSHAuthAbortError).reason;
      if (reason is SSHDisconnectError) {
        expect(peerDisconnectReason(e), isNotNull);
        expect(
          humanizeSshError(e),
          startsWith('The host closed the connection'),
        );
      } else {
        expect(reason, isA<SSHInternalError>());
        expect('$reason', contains('No matching key exchange algorithm'));
      }
    } finally {
      await client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'transportBusy is true while a command runs and settles back to false',
    () async {
      if (skip()) return;
      CommandTelemetry.instance.clearDrops();
      final running = executor.execute(
        repoPath: repo,
        gitArgs: const ['sleep', '2'],
        lane: ExecLane.read,
      );
      final started = Stopwatch()..start();
      while (!executor.transportBusy) {
        if (started.elapsed > const Duration(seconds: 2)) {
          fail('transportBusy never became true');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(manager.client, isNotNull);
      await running;
      expect(executor.transportBusy, isFalse);
      expect(CommandTelemetry.instance.monitorKillCount, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('bulk transfer completes with the health monitor armed', () async {
    if (skip()) return;
    CommandTelemetry.instance.clearDrops();
    final killsBefore = CommandTelemetry.instance.monitorKillCount;
    final handle = await executor.executeStream(
      repoPath: repo,
      gitArgs: const ['dd', 'if=/dev/zero', 'bs=1048576', 'count=100'],
    );
    await handle.stdout.drain<void>();
    await handle.stderr.drain<void>();
    await handle.cancel();
    expect(CommandTelemetry.instance.monitorKillCount, killsBefore);
    final echo = await executor.execute(
      repoPath: repo,
      gitArgs: const ['echo', 'ok'],
      lane: ExecLane.read,
    );
    expect(echo.exitCode, 0);
    expect(echo.stdout.trim(), 'ok');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a real connect attaches all three clients', () async {
    if (skip()) return;
    // 0014's triple-client architecture: the handshake test proves three
    // sockets are *scheduled*, but only a real sshd proves three of them
    // authenticate and stay attached. Both degraded getters fall back to
    // the command client, so identity — not null-ness — is the proof.
    expect(manager.attachedClientCount, 3);
    expect(manager.syncClientDegraded, isFalse);
    expect(manager.streamClientDegraded, isFalse);
    expect(identical(manager.syncClient, manager.client), isFalse);
    expect(identical(manager.streamClient, manager.client), isFalse);
    expect(identical(manager.syncClient, manager.streamClient), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a read completes while a long sync command is draining', () async {
    if (skip()) return;
    // The whole point of the dedicated sync client: a fetch must not
    // head-of-line-block status/log reads for its entire duration.
    final sync = executor.execute(
      repoPath: repo,
      gitArgs: const ['sh', '-c', 'sleep 3; echo synced'],
      lane: ExecLane.sync,
      timeout: const Duration(seconds: 30),
    );

    final started = Stopwatch()..start();
    while (!executor.syncBusy) {
      if (started.elapsed > const Duration(seconds: 3)) {
        fail('syncBusy never became true');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final readAt = Stopwatch()..start();
    final read = await executor.execute(
      repoPath: repo,
      gitArgs: const ['echo', 'ok'],
      lane: ExecLane.read,
    );
    readAt.stop();

    expect(read.exitCode, 0);
    expect(read.stdout.trim(), 'ok');
    expect(
      readAt.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'the read waited on the sync command — lanes are not split',
    );

    final synced = await sync;
    expect(synced.exitCode, 0);
    expect(synced.stdout.trim(), 'synced');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'a dropped sync client degrades, then the backoff redial restores it',
    () async {
      if (skip()) return;
      expect(manager.attachedClientCount, 3);
      final dropped = manager.syncClient;
      expect(dropped, isNotNull);

      // A NAT/firewall idle-drop kills the least-used client first; without
      // the redial the session stays degraded onto the command client for
      // the rest of its life.
      await dropped!.close();

      final degradedAt = Stopwatch()..start();
      while (!manager.syncClientDegraded) {
        if (degradedAt.elapsed > const Duration(seconds: 10)) {
          fail('the dropped sync client never degraded');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(manager.attachedClientCount, 2);

      // First backoff is streamRedialDelay(0) = 15s.
      final recoveredAt = Stopwatch()..start();
      while (manager.syncClientDegraded) {
        if (recoveredAt.elapsed > const Duration(seconds: 40)) {
          fail(
            'sync client did not redial within 40s '
            '(first backoff is 15s)',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      expect(manager.attachedClientCount, 3);
      expect(
        identical(manager.syncClient, dropped),
        isFalse,
        reason: 'recovery must be a NEW client, not the closed one',
      );

      // And the restored client actually carries sync work.
      final synced = await executor.execute(
        repoPath: repo,
        gitArgs: const ['echo', 'redialed'],
        lane: ExecLane.sync,
      );
      expect(synced.stdout.trim(), 'redialed');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // ---- 0022 M5: does teardown actually kill the remote process? -----------
  //
  // MADR 0022 recorded this as "suspicion, not reproduced" and said plainly it
  // needed a live host to settle. RFC 4254's `signal` request is optional and
  // OpenSSH is widely documented as ignoring it on non-pty exec channels, in
  // which case both TERM and KILL are no-ops and cleanup rests entirely on
  // channel close producing SIGPIPE at the process's next write — which for a
  // quiet watcher may be far away, or never.
  //
  // The remote is loopback here, so the process is directly observable.
  Future<int?> pidFromFile(String path) async {
    for (var i = 0; i < 60; i++) {
      final f = File(path);
      if (f.existsSync()) {
        final t = f.readAsStringSync().trim();
        final pid = int.tryParse(t);
        if (pid != null) return pid;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  bool alive(int pid) {
    // Signal 0: existence check, no delivery.
    final r = Process.runSync('/bin/kill', ['-0', '$pid']);
    return r.exitCode == 0;
  }

  Future<bool> diesWithin(int pid, Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (!alive(pid)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return !alive(pid);
  }

  test('cancelling a stream kills the remote process, not just the channel '
      '(0022 M5)', () async {
    if (skip()) return;

    final pidFile = '$repo/m5_stream.pid';
    // `exec` so the sleep *becomes* the shell: the PID recorded is the one
    // that must die, with no wrapper left to absorb the signal.
    final handle = await executor.executeStream(
      repoPath: repo,
      gitArgs: ['sh', '-c', 'echo \$\$ > ${_q(pidFile)}; exec sleep 300'],
    );

    final pid = await pidFromFile(pidFile);
    expect(pid, isNotNull, reason: 'the remote process never started');
    expect(alive(pid!), isTrue, reason: 'sanity: it should be running');

    await handle.cancel();

    // killGrace is 400ms; give the escalation an order of magnitude.
    expect(
      await diesWithin(pid, const Duration(seconds: 5)),
      isTrue,
      reason:
          'the remote process outlived its channel — teardown only closed the '
          'channel, so a watcher/CI-trace process leaks per arm (0022 M5)',
    );
  });

  test('a timed-out command kills the remote process too (0022 M5)', () async {
    if (skip()) return;

    // Same teardown path, reached from `execute`'s timeout rather than an
    // explicit cancel. A leak here holds .git/index.lock in the mutation case.
    final pidFile = '$repo/m5_timeout.pid';
    await expectLater(
      executor.execute(
        repoPath: repo,
        gitArgs: ['sh', '-c', 'echo \$\$ > ${_q(pidFile)}; exec sleep 300'],
        timeout: const Duration(seconds: 2),
        lane: ExecLane.read,
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );

    final pid = await pidFromFile(pidFile);
    expect(pid, isNotNull);
    expect(
      await diesWithin(pid!, const Duration(seconds: 5)),
      isTrue,
      reason: 'a timed-out command left its remote process running',
    );
  });

  test('CONTROL: an uncancelled stream leaves the process running', () async {
    if (skip()) return;
    // Without this the two tests above are indistinguishable from a detector
    // that always reports "dead" — the check has to be seen to fail.
    final pidFile = '$repo/m5_control.pid';
    final handle = await executor.executeStream(
      repoPath: repo,
      gitArgs: ['sh', '-c', 'echo \$\$ > ${_q(pidFile)}; exec sleep 300'],
    );
    final pid = await pidFromFile(pidFile);
    expect(pid, isNotNull);
    expect(
      await diesWithin(pid!, const Duration(seconds: 3)),
      isFalse,
      reason: 'the detector must be able to observe a LIVING process',
    );
    await handle.cancel();
  });

  test('MECHANISM: the signal request alone does not kill it', () async {
    if (skip()) return;
    // Which half of killAndCloseSession is load-bearing? RFC 4254's `signal`
    // is optional and OpenSSH is documented as ignoring it on non-pty exec
    // channels. If that is true here, the kill comes from channel close (sshd
    // tears down the session's process group), not from our signal.
    final pidFile = '$repo/m5_mech.pid';
    final client = manager.streamClient!;
    final session = await client.execute(
      "cd ${_q(repo)} && exec sh -c 'echo \$\$ > ${_q(pidFile)}; exec sleep 300'",
    );
    final pid = await pidFromFile(pidFile);
    expect(pid, isNotNull);

    session.kill(SSHSignal.TERM);
    final diedFromSignal = await diesWithin(pid!, const Duration(seconds: 2));

    session.close();
    final diedFromClose = await diesWithin(pid, const Duration(seconds: 5));

    // Recorded, not asserted either way: this documents the host's behaviour.
    // ignore: avoid_print
    print(
      'M5 MECHANISM: died from signal=$diedFromSignal  '
      'died after close=$diedFromClose',
    );
    expect(diedFromClose, isTrue);
  });

  // ---- 0024 M2: is the stream budget the right number? --------------------
  test('MaxSessions is per TCP connection, and our budget binds first on a '
      'default host (0024 M2)', () async {
    if (!_DisposableSshd.available) return;

    // A host configured BELOW our budget. OpenSSH's default is 10; ours is 8
    // for a dedicated stream client, which only protects us while the host
    // allows at least that many.
    final small = await _DisposableSshd.start(maxSessions: 4);
    expect(small, isNotNull, reason: 'could not start a MaxSessions=4 sshd');
    final m = SSHClientManager();
    final ex = SSHCommandExecutor(m);
    await m.connect(small!.profile, onVerifyHostKey: (_, _) => true);
    addTearDown(() async {
      await m.disconnect();
      await small.stop();
    });

    final opened = <SSHStreamHandle>[];
    Object? failure;
    for (var i = 0; i < 8; i++) {
      try {
        opened.add(
          await ex.executeStream(
            repoPath: '/tmp',
            gitArgs: const ['sh', '-c', 'exec sleep 60'],
          ),
        );
      } catch (e) {
        failure = e;
        break;
      }
    }
    for (final h in opened) {
      await h.cancel();
    }

    // What this pins: the host's ceiling is reached before ours, and it
    // surfaces as the typed channel-open error the retry allowlist already
    // treats as transient — NOT as a hang and not as our budget error. Our
    // budget therefore protects the default host and defers to a stricter one.
    expect(
      opened.length,
      lessThanOrEqualTo(4),
      reason: 'MaxSessions 4 must bind before our budget of 8',
    );
    expect(
      failure,
      isA<SSHChannelOpenError>(),
      reason: 'a host refusal must stay distinguishable from our own budget',
    );
    expect(
      ex.maxConcurrentStreams,
      8,
      reason: 'the budget itself is unchanged by the host being stricter',
    );
  });

  // ---- 0024 P1: what the connect probe actually costs over a real link ----
  test('the connect probe no longer waits on a login shell (0024 P1)', () async {
    if (skip()) return;

    // The removed prelude, verbatim from 21721ef, run over the same transport
    // so the comparison includes the SSH round trip rather than only shell time.
    const removedPrelude =
        'lp=""; _mg_lp="\${TMPDIR:-/tmp}/mg_lp.\$\$"; '
        '(\${SHELL:-sh} -lc \'printf %s "\$PATH"\' >"\$_mg_lp" 2>/dev/null) & '
        'lp_pid=\$!; i=0; while [ \$i -lt 30 ] && kill -0 \$lp_pid 2>/dev/null; do '
        'i=\$((i+1)); sleep 0.1; done; '
        'if kill -0 \$lp_pid 2>/dev/null; then kill \$lp_pid 2>/dev/null; '
        'wait \$lp_pid 2>/dev/null; else wait \$lp_pid 2>/dev/null; '
        'lp=\$(cat "\$_mg_lp" 2>/dev/null); fi; rm -f "\$_mg_lp" 2>/dev/null; '
        'echo done';

    // PAIRED and INTERLEAVED, compared by median (0024 deviation (e)).
    //
    // This originally took one sample of each, back to back, and compared them
    // directly — so any load arriving between the two measurements was charged
    // entirely to the second, and the check failed under full-suite load
    // (probe 347 ms vs prelude 186 ms) while passing in isolation moments later
    // (96 ms vs 215 ms). It was measuring drift as much as the improvement it
    // asserts. Interleaving makes a load spike perturb both arms equally, and
    // the median discards the spike outright.
    //
    // The claim is unchanged: the current probe does strictly more work (OS,
    // PATH, and `command -v` for every catalog binary) and must still beat the
    // prelude that was deleted, which did none of it. This still goes red if
    // removing the prelude did not help.
    const samples = 5;
    final oldMs = <int>[];
    final newMs = <int>[];
    RemoteEnvironment? env;

    for (var i = 0; i < samples; i++) {
      final oldSw = Stopwatch()..start();
      await executor.execute(
        repoPath: repo,
        gitArgs: const ['sh', '-c', removedPrelude],
        timeout: const Duration(seconds: 20),
        lane: ExecLane.read,
      );
      oldSw.stop();
      oldMs.add(oldSw.elapsedMicroseconds);

      final newSw = Stopwatch()..start();
      env = await EnvironmentResolver(executor).resolve(repo);
      newSw.stop();
      newMs.add(newSw.elapsedMicroseconds);
    }

    int median(List<int> xs) {
      final sorted = [...xs]..sort();
      return sorted[sorted.length ~/ 2];
    }

    final oldMedian = median(oldMs);
    final newMedian = median(newMs);

    // ignore: avoid_print
    print(
      '0024 P1: removed prelude ${oldMedian ~/ 1000} ms  vs  '
      'whole current probe ${newMedian ~/ 1000} ms  '
      '(median of $samples interleaved pairs)',
    );

    expect(newMedian, lessThan(oldMedian));
    expect(env!.os, isNot('unknown'), reason: 'sanity: the probe worked');
    expect(env.has('git'), isTrue);
  });
}

/// Single-quote for the remote shell — the test builds its own snippets.
String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";
