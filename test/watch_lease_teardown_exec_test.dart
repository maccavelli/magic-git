// MADR 0041. These tests EXECUTE the lease loop against real processes.
//
// The finding they exist for: a teardown on the client does not reach the
// watcher on the host. `session.kill(TERM)` is an RFC 4254 "signal" channel
// request OpenSSH's sshd does not implement, closing the channel reaches a
// process blocked in `select()` not at all, and the client performed no
// host-side cleanup — so a watcher outlived its client by up to six minutes,
// and the only thing bounding the residue was a ceiling of two.
//
// Measured on a real bastion before any of this was written: reproduce the old
// loop's shape, kill the client, and the whole tree survives indefinitely. With
// the shape under test here, it is gone in under five seconds.
//
// So: no `contains(...)` assertions about script text in this file. Start the
// real generated script, do the thing to it, and look at the process table.
// `bounded_watch_test.dart` is its composition-only twin.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';

/// True while [pid] is a live process. `kill -0` is the POSIX liveness probe.
Future<bool> isAlive(int pid) async =>
    (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;

/// Waits for [pid] to die, up to [tries] × 100 ms. Signal delivery is not
/// instantaneous and a fixed sleep would be flaky under load.
Future<bool> diedWithin(int pid, {int tries = 50}) async {
  for (var i = 0; i < tries; i++) {
    if (!await isAlive(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

/// Waits for [predicate], up to [tries] × 100 ms. Same reasoning.
Future<bool> settles(
  Future<bool> Function() predicate, {
  int tries = 50,
}) async {
  for (var i = 0; i < tries; i++) {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

void main() {
  late Directory dir;
  late String shimDir;
  final spawned = <Process>[];

  /// Marker in the shim watcher's argv, so a census can find it (and only it)
  /// in the process table without matching this test's own command line.
  const marker = 'mg-lease-exec-probe';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mg-lease-teardown-');
    shimDir = '${dir.path}/bin';
    Directory(shimDir).createSync();
    Directory('${dir.path}/.git').createSync();
    // The blocking payload, reached through a marker-named symlink so its argv
    // identifies it in the process table. A marker passed as an ARGUMENT does
    // not work: `sleep 300 <marker>` is an invalid operand on both GNU and BSD
    // sleep, so the payload exits at once and every liveness assertion below
    // reads zero for the wrong reason. (It did, on the first run.)
    await Process.run('ln', ['-sf', '/bin/sleep', '$shimDir/$marker']);
    // Stands in for `inotifywait -m`: records that it armed, then blocks
    // forever. `exec`, so the shim shell is replaced and the process the loop
    // supervises is the payload itself.
    File('$shimDir/inotifywait').writeAsStringSync(
      '#!/bin/sh\n'
      'echo x >> "${dir.path}/arms"\n'
      'exec "$shimDir/$marker" 300\n',
    );
    await Process.run('chmod', ['+x', '$shimDir/inotifywait']);
  });

  tearDown(() async {
    for (final p in spawned) {
      p.kill(ProcessSignal.sigkill);
    }
    spawned.clear();
    // Nothing may outlive a test in this file — that is the whole subject.
    await Process.run('pkill', ['-f', marker]);
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  String pidPath() => '${dir.path}/.git/mg-watch.t.pid';
  String hbPath() => '${dir.path}/.git/mg-watch.t.hb';

  int arms() {
    final f = File('${dir.path}/arms');
    if (!f.existsSync()) return 0;
    return f.readAsLinesSync().where((l) => l.isNotEmpty).length;
  }

  String script({String token = 't', WatchLock? lock}) => recursiveWatchScript(
    inotify: true,
    excludes: '',
    pidFile: '${dir.path}/.git/mg-watch.$token.pid',
    heartbeat: '${dir.path}/.git/mg-watch.$token.hb',
    lock: lock,
    // Short enough that the backstop can be observed inside a test.
    leasePoll: const Duration(seconds: 1),
  );

  /// Starts the real script with a live stdin pipe — which is what an SSH
  /// channel gives it. Dart's default start mode pipes stdin and leaves it
  /// open, which is the condition case (c) depends on.
  Future<Process> start({String token = 't', WatchLock? lock}) async {
    final p = await Process.start(
      'sh',
      ['-c', script(token: token, lock: lock)],
      workingDirectory: dir.path,
      environment: {'PATH': '$shimDir:${Platform.environment['PATH']}'},
    );
    spawned.add(p);
    return p;
  }

  /// The shim watchers alive right now, by argv marker.
  Future<int> liveWatchers() async {
    final r = await Process.run('sh', [
      '-c',
      'ps -eo args | grep -c "[m]g-lease-exec-probe 300"',
    ]);
    return int.tryParse((r.stdout as String).trim()) ?? 0;
  }

  // (a) and (b): the two pre-checks. Both existed before; what is new is that
  // they no longer leave the pid file the prelude wrote — litter of exactly
  // that shape is what made a re-armed repository read as two live watchers
  // (0041 F4).

  test(
    'no heartbeat: exits at once, arms nothing, leaves no pid file',
    () async {
      final p = await start();
      final code = await p.exitCode.timeout(const Duration(seconds: 10));

      expect(code, 0, reason: 'exits cleanly rather than watching forever');
      expect(arms(), 0, reason: 'the lease is checked BEFORE arming');
      expect(
        File(pidPath()).existsSync(),
        isFalse,
        reason:
            'the prelude wrote it before the lease was examined; an exit path '
            'that leaves it behind is litter only a connect-time sweep can '
            'reclaim',
      );
    },
  );

  test('stale heartbeat: exits at once and leaves no pid file', () async {
    File(hbPath()).writeAsStringSync('');
    // Older than staleAfter (5 min) by any measure.
    await Process.run('touch', ['-t', '202001010000', hbPath()]);

    final p = await start();
    final code = await p.exitCode.timeout(const Duration(seconds: 10));

    expect(code, 0);
    expect(arms(), 0);
    expect(File(pidPath()).existsSync(), isFalse);
  });

  // (c) MUST come before (d) and must be asserted, not assumed. A test that
  // forgets to leave stdin open reproduces the /dev/null trap the loop is
  // written around — the watchdog fires the instant it starts — and then (d)
  // passes for entirely the wrong reason. This is what makes (d) non-vacuous.

  test('fresh lease with stdin open: arms once and stays armed', () async {
    File(hbPath()).writeAsStringSync('');
    final p = await start();

    expect(
      await settles(() async => arms() == 1),
      isTrue,
      reason: 'the watcher armed',
    );
    // Several lease polls later it must still be there.
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(arms(), 1, reason: 'armed once and kept, never re-walked');
    expect(await liveWatchers(), 1, reason: 'the watcher is still running');
    expect(
      File(pidPath()).existsSync(),
      isTrue,
      reason: 'a live watcher keeps its registry entry',
    );
    expect(
      await isAlive(p.pid),
      isTrue,
      reason:
          'nothing may kill the loop while its client holds stdin open — if '
          'this fails, the eof watchdog is reading fd 0 rather than the saved '
          'descriptor and fired against /dev/null',
    );
  });

  // (d) The finding itself. Closing stdin is what a channel close does, and it
  // is the only signal that reaches a process the client cannot signal.

  test('stdin EOF takes the whole tree down and clears the registry', () async {
    File(hbPath()).writeAsStringSync('');
    final p = await start();
    expect(await settles(() async => arms() == 1), isTrue);
    expect(await liveWatchers(), 1);

    await p.stdin.close();

    expect(
      await diedWithin(p.pid),
      isTrue,
      reason: 'the loop shell must go with its client',
    );
    expect(
      await settles(() async => await liveWatchers() == 0),
      isTrue,
      reason:
          'and take the watcher with it — this is the six-minute residue the '
          'record was written about',
    );
    expect(
      await settles(() async => !File(pidPath()).existsSync()),
      isTrue,
      reason: 'cleanup removes what the prelude wrote',
    );
  });

  // (e) The backstop, for a client that stops beating while the connection
  // stays up. It must fire WITHOUT the watcher having to exit first, which is
  // the whole difference from the loop this replaced.

  test('a lease that goes stale takes the tree down too', () async {
    File(hbPath()).writeAsStringSync('');
    final p = await start();
    expect(await settles(() async => arms() == 1), isTrue);

    // The client stops refreshing, and the lease ages past staleAfter. stdin
    // stays open throughout, so only the poll can notice.
    await Process.run('touch', ['-t', '202001010000', hbPath()]);

    expect(await diedWithin(p.pid), isTrue);
    expect(await settles(() async => await liveWatchers() == 0), isTrue);
    expect(await settles(() async => !File(pidPath()).existsSync()), isTrue);
    expect(
      arms(),
      1,
      reason: 'the lease was re-read without re-arming the watcher',
    );
  });

  // (f) What pins the `exec`. Without it the loop's child is the subshell that
  // `{ …; } &` forked and the watcher is that subshell's child, so the kill
  // lands on the wrapper and orphans the watcher — MADR 0041 F1's process tree,
  // and what the previous `kill "$c"` did for as long as it existed.

  test('the process it supervises is the watcher, not a wrapper', () async {
    File(hbPath()).writeAsStringSync('');
    final p = await start();
    expect(await settles(() async => arms() == 1), isTrue);

    final r = await Process.run('sh', [
      '-c',
      'ps -eo ppid,args | awk \'\$1 == ${p.pid}\' '
          '| grep -c "[m]g-lease-exec-probe 300"',
    ]);
    expect(
      int.tryParse((r.stdout as String).trim()),
      1,
      reason:
          'the watcher must be a DIRECT child of the loop shell. If it is a '
          'grandchild, `kill "\$w"` signals the wrapper and the watcher '
          'survives — the defect this file exists to prevent',
    );
  });

  // ---- the host-side claim (MADR 0041 phase 3) --------------------------
  //
  // The client's slot counter is correct only while exactly one client exists.
  // This app has had up to eight tab containers since `11689cc`, two saved
  // connections can reach one host by different ids, and nothing stops a second
  // copy of the app entirely. Exclusion that survives all three has to live on
  // the host, so it is a `mkdir` — atomic on any POSIX filesystem, and present
  // on the macOS hosts this app also targets, where `flock(1)` is not.

  group('one watcher per repository', () {
    WatchLock lockFor(String token) =>
        (gitDir: '${dir.path}/.git', token: token);

    test(
      'a second arm is refused while the first holds a fresh lease',
      () async {
        File('${dir.path}/.git/mg-watch.a.hb').writeAsStringSync('');
        final first = await start(token: 'a', lock: lockFor('a'));
        expect(await settles(() async => arms() == 1), isTrue);

        File('${dir.path}/.git/mg-watch.b.hb').writeAsStringSync('');
        final second = await start(token: 'b', lock: lockFor('b'));
        final code = await second.exitCode.timeout(const Duration(seconds: 10));

        expect(
          code,
          boundedWatchLockedExit,
          reason:
              'a distinct status, so the caller can degrade rather than '
              'spend three restarts on a watcher that will never arm',
        );
        expect(arms(), 1, reason: 'and it never armed a second watcher');
        expect(await liveWatchers(), 1);
        expect(
          File('${dir.path}/.git/mg-watch.b.pid').existsSync(),
          isFalse,
          reason: 'a refusal claims nothing, so it leaves nothing',
        );
        expect(
          await isAlive(first.pid),
          isTrue,
          reason: 'the holder is untouched',
        );
      },
    );

    test('a lock whose holder is gone is stolen, not respected', () async {
      File('${dir.path}/.git/mg-watch.a.hb').writeAsStringSync('');
      final first = await start(token: 'a', lock: lockFor('a'));
      expect(await settles(() async => arms() == 1), isTrue);

      // The holder crashed: its lock is still there, its lease is not fresh.
      first.kill(ProcessSignal.sigkill);
      await Process.run('pkill', ['-f', marker]);
      await Process.run('touch', [
        '-t',
        '202001010000',
        '${dir.path}/.git/mg-watch.a.hb',
      ]);
      expect(
        Directory('${dir.path}/.git/mg-watch.lock').existsSync(),
        isTrue,
        reason:
            'a SIGKILLed holder cannot run its own trap — that is the '
            'case this steal exists for',
      );

      File('${dir.path}/.git/mg-watch.b.hb').writeAsStringSync('');
      await start(token: 'b', lock: lockFor('b'));

      expect(
        await settles(() async => await liveWatchers() == 1),
        isTrue,
        reason: 'refusing forever would let one crash poison the repository',
      );
      expect(
        File('${dir.path}/.git/mg-watch.lock/token').readAsStringSync(),
        'b',
        reason: 'and the claim now names the live holder',
      );
    });

    test('a clean exit releases the claim', () async {
      File('${dir.path}/.git/mg-watch.a.hb').writeAsStringSync('');
      final p = await start(token: 'a', lock: lockFor('a'));
      expect(await settles(() async => arms() == 1), isTrue);
      expect(Directory('${dir.path}/.git/mg-watch.lock').existsSync(), isTrue);

      await p.stdin.close();

      expect(
        await settles(
          () async => !Directory('${dir.path}/.git/mg-watch.lock').existsSync(),
        ),
        isTrue,
        reason: 'a watcher that goes must not leave a claim behind it',
      );
    });

    test(
      'a watcher whose claim was stolen does not delete the new one',
      () async {
        File('${dir.path}/.git/mg-watch.a.hb').writeAsStringSync('');
        final p = await start(token: 'a', lock: lockFor('a'));
        expect(await settles(() async => arms() == 1), isTrue);

        // Simulate the steal: the lock now names someone else.
        File(
          '${dir.path}/.git/mg-watch.lock/token',
        ).writeAsStringSync('someone-else');

        await p.stdin.close();
        expect(await diedWithin(p.pid), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(
          Directory('${dir.path}/.git/mg-watch.lock').existsSync(),
          isTrue,
          reason:
              'releasing a claim it no longer holds would delete a live '
              "watcher's exclusion",
        );
      },
    );

    test('the sweep reclaims a stale claim and spares a fresh one', () async {
      final stale = Directory('${dir.path}/.git/mg-watch.lock')
        ..createSync(recursive: true);
      File('${stale.path}/token').writeAsStringSync('ghost');
      File('${dir.path}/.git/mg-watch.ghost.hb').writeAsStringSync('');
      await Process.run('touch', [
        '-t',
        '202001010000',
        '${dir.path}/.git/mg-watch.ghost.hb',
      ]);

      await Process.run('sh', [
        '-c',
        watcherSweepScript([
          '${dir.path}/.git',
        ], staleAfter: const Duration(minutes: 5)),
      ]);
      expect(
        stale.existsSync(),
        isFalse,
        reason: 'a claim whose holder is gone refuses every future watcher',
      );

      // Now a live one, which the sweep must not touch.
      stale.createSync(recursive: true);
      File('${stale.path}/token').writeAsStringSync('live');
      File('${dir.path}/.git/mg-watch.live.hb').writeAsStringSync('');
      await Process.run('sh', [
        '-c',
        watcherSweepScript([
          '${dir.path}/.git',
        ], staleAfter: const Duration(minutes: 5)),
      ]);
      expect(
        stale.existsSync(),
        isTrue,
        reason:
            "a fresh lease means a live watcher, possibly another session's",
      );
    });
  });

  // ---- the teardown seam (MADR 0043 phase 2) -----------------------------
  //
  // The host releases its lock in well under a second after a channel closes
  // (0043 F4). Under a second is not zero, and an arm that reaches the host
  // inside that window is refused by its OWN predecessor — a healthy
  // repository degrading to polling because it collided with itself.
  //
  // These run the real generated script against real processes, because the
  // window only exists on a real host and a fake executor cannot have one.

  group('a re-arm does not collide with its own predecessor', () {
    WatchLock lockFor(String token) =>
        (gitDir: '${dir.path}/.git', token: token);

    test(
      'the client releases the lock without waiting for the watcher',
      () async {
        File('${dir.path}/.git/mg-watch.a.hb').writeAsStringSync('');
        final first = await start(token: 'a', lock: lockFor('a'));
        expect(await settles(() async => arms() == 1), isTrue);
        expect(
          Directory('${dir.path}/.git/mg-watch.lock').existsSync(),
          isTrue,
          reason: 'the first watcher holds the claim',
        );

        // What the client's teardown issues, verbatim from the production
        // builder — the guarded release, run while the watcher is still alive.
        await Process.run('sh', ['-c', watchLockReleaseScript(lockFor('a'))]);

        expect(
          Directory('${dir.path}/.git/mg-watch.lock').existsSync(),
          isFalse,
          reason:
              'the client owns this claim and can give it back immediately, '
              'rather than waiting for the watcher to notice its channel closed',
        );

        // And a fresh arm now succeeds where it would have been refused.
        File('${dir.path}/.git/mg-watch.b.hb').writeAsStringSync('');
        final second = await start(token: 'b', lock: lockFor('b'));
        expect(
          await settles(() async => arms() == 2),
          isTrue,
          reason:
              'the successor arms instead of being refused by its own '
              'predecessor',
        );

        first.kill(ProcessSignal.sigkill);
        second.kill(ProcessSignal.sigkill);
      },
    );

    test('the release refuses to remove a claim it no longer owns', () async {
      File('${dir.path}/.git/mg-watch.a.hb').writeAsStringSync('');
      final p = await start(token: 'a', lock: lockFor('a'));
      expect(await settles(() async => arms() == 1), isTrue);

      // Someone else took it over in the meantime — the steal path exists so a
      // crashed holder cannot poison a repository, and it can land between a
      // client deciding to tear down and its release actually running.
      File(
        '${dir.path}/.git/mg-watch.lock/token',
      ).writeAsStringSync('someone-else');

      await Process.run('sh', ['-c', watchLockReleaseScript(lockFor('a'))]);

      expect(
        Directory('${dir.path}/.git/mg-watch.lock').existsSync(),
        isTrue,
        reason:
            'removing a claim this token no longer holds would delete a live '
            "watcher's exclusion and let a third arm in",
      );
      p.kill(ProcessSignal.sigkill);
    });
  });
}
