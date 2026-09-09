// MADR 0027. These tests EXECUTE the sweep script against real processes.
//
// That is the whole point. The sweep shipped with two halves that are each
// individually correct and contradict each other — it records a shell's pid and
// then refuses to signal anything whose identity is not a watcher binary — and
// the only test asserted the script's *text* (`contains('inotifywait')`,
// `contains('kill -TERM')`), which cannot see a contradiction between two
// strings that are both present.
//
// So: no `contains(...)` assertions about script text in this file. Spawn a
// process, run the script, look at whether the process is still there.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';

/// True while [pid] is a live process. `kill -0` is the POSIX liveness probe.
Future<bool> isAlive(int pid) async {
  final r = await Process.run('kill', ['-0', '$pid']);
  return r.exitCode == 0;
}

/// Waits for [pid] to die, up to [tries] × 100 ms. Signal delivery is not
/// instantaneous, and a fixed sleep would make this flaky under load.
Future<bool> diedWithin(int pid, {int tries = 30}) async {
  for (var i = 0; i < tries; i++) {
    if (!await isAlive(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

Future<ProcessResult> runScript(String script) =>
    Process.run('sh', ['-c', script]);

void main() {
  late Directory tmp;
  final spawned = <Process>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mg-sweep-');
  });

  tearDown(() async {
    for (final p in spawned) {
      p.kill(ProcessSignal.sigkill);
    }
    spawned.clear();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Spawns a stand-in watcher: a shell that records its own pid into
  /// [pidFile] and then blocks — the same shape the real lease shell has, so
  /// its command line carries the pid-file path exactly as production's does.
  Future<Process> spawnWatcher(String pidFile) async {
    final p = await Process.start('sh', [
      '-c',
      'printf %s "\$\$" > ${_esc(pidFile)}; sleep 300',
    ]);
    spawned.add(p);
    // Wait for the pid file to appear so the sweep has something to read.
    for (var i = 0; i < 30; i++) {
      if (File(pidFile).existsSync() &&
          File(pidFile).readAsStringSync().isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return p;
  }

  test('the sweep reclaims an orphaned watcher', () async {
    final pidFile = '${tmp.path}/mg-watch.tok1.pid';
    final proc = await spawnWatcher(pidFile);
    expect(await isAlive(proc.pid), isTrue, reason: 'fixture must be running');

    // No heartbeat file at all: the owner is gone, which is what an orphan is.
    await runScript(
      watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
    );

    expect(
      await diedWithin(proc.pid),
      isTrue,
      reason: 'an orphaned watcher must be reclaimed',
    );
    expect(
      File(pidFile).existsSync(),
      isFalse,
      reason: 'its file is cleaned up',
    );
  });

  test('a fresh sibling heartbeat does not protect an orphan', () async {
    // THE PRODUCTION SCENARIO. One repo, two watcher instances: one live with
    // its client refreshing its lease, one orphaned. This is exactly the state
    // on the host after a rebuild-and-relaunch, and it is how two orphans
    // survived a sweep and reached 19 minutes (0027 defect 2/3).
    final orphanPid = '${tmp.path}/mg-watch.dead.pid';
    final livePid = '${tmp.path}/mg-watch.live.pid';
    final orphan = await spawnWatcher(orphanPid);
    final live = await spawnWatcher(livePid);

    // The LIVE instance's owner is alive and refreshing its own lease.
    // The orphan's lease file does not exist: nobody is refreshing it.
    File('${tmp.path}/mg-watch.live.hb').writeAsStringSync('');

    await runScript(
      watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
    );

    expect(
      await diedWithin(orphan.pid),
      isTrue,
      reason: "a sibling's fresh heartbeat must not keep an orphan alive",
    );
    expect(
      await isAlive(live.pid),
      isTrue,
      reason: 'the live watcher must survive its own sweep',
    );
  });

  test('a legacy untokenised pair is reclaimed and removed', () async {
    // Hosts that ran a pre-0027 build carry `mg-watch.pid` / `mg-watch.hb`
    // with no token — including the two orphans that motivated this record.
    // If the sweep only matched the tokenised shape, the very processes this
    // work exists to reclaim would run forever.
    final pidFile = '${tmp.path}/mg-watch.pid';
    final proc = await spawnWatcher(pidFile);

    await runScript(
      watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
    );

    expect(
      await diedWithin(proc.pid),
      isTrue,
      reason: 'a legacy orphan must be reclaimed, not stranded',
    );
    expect(File(pidFile).existsSync(), isFalse);
  });

  test('the sweep spares a process that is not ours', () async {
    // A pid file naming a process whose command line carries no marker of
    // ours — a recycled pid, or another tool. Killing it would be the
    // "wrong processes in the kill set" failure 0025 records.
    final pidFile = '${tmp.path}/mg-watch.tok2.pid';
    final other = await Process.start('sh', ['-c', 'sleep 300']);
    spawned.add(other);
    File(pidFile).writeAsStringSync('${other.pid}');

    await runScript(
      watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      await isAlive(other.pid),
      isTrue,
      reason: 'a process that is not ours must never be signalled',
    );
  });

  test('a stale heartbeat with no pid file is pruned', () async {
    // The sweep iterates PID files and derives the heartbeat from them, so a
    // heartbeat whose pid file is absent was never visited — it accumulated,
    // one per failed arm, forever. Three were found on the host aged 14.5
    // hours (0027 deviation (c)).
    final orphanHb = File('${tmp.path}/mg-watch.gone.hb')
      ..writeAsStringSync('');
    // Older than staleAfter by any measure.
    await Process.run('touch', ['-t', '202001010000', orphanHb.path]);
    await runScript(
      watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
    );
    expect(
      orphanHb.existsSync(),
      isFalse,
      reason: 'an owner-less, stale lease file is litter and must be removed',
    );
  });
  test(
    'a FRESH heartbeat with no pid file is spared — that is an arm in flight',
    () async {
      // Since the lease is stamped before the watcher is armed, "heartbeat, no
      // pid file" is also exactly what a watcher that is still starting looks
      // like. Deleting one would pull the lease out from under a script about to
      // check for it — reintroducing the arm-race failure by a different route.
      final fresh = File('${tmp.path}/mg-watch.starting.hb')
        ..writeAsStringSync('');
      await runScript(
        watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
      );
      expect(
        fresh.existsSync(),
        isTrue,
        reason:
            'a lease stamped seconds ago belongs to an arm still starting up',
      );
    },
  );

  test('the sweep REPORTS the tokens still leased, and only those', () async {
    // MADR 0040 phase 3. The client reconciles its slot bookkeeping against this
    // output, so what the script actually prints is the contract — asserted by
    // running it, not by reading it (MADR 0029).
    final livePid = '${tmp.path}/mg-watch.alive.pid';
    await spawnWatcher(livePid);
    // A fresh heartbeat: some client is still refreshing this one.
    File('${tmp.path}/mg-watch.alive.hb').writeAsStringSync('');

    // A stale heartbeat with no pid beside it — what an arm that failed after
    // stamping its lease leaves behind. Litter, not a live watcher.
    final stale = File('${tmp.path}/mg-watch.stranded.hb')
      ..writeAsStringSync('');
    await Process.run('touch', ['-t', '202601010000', stale.path]);

    final out = await runScript(
      watcherSweepScript([tmp.path], staleAfter: const Duration(minutes: 5)),
    );

    expect(out.exitCode, 0, reason: 'reporting must not fail the reclamation');
    final reported = const LineSplitter()
        .convert(out.stdout as String)
        .where((l) => l.startsWith('LIVE '))
        .map((l) => l.substring(5).trim())
        .toList();

    expect(
      reported,
      contains('alive'),
      reason: 'a fresh lease is a watcher some client is still refreshing',
    );
    expect(
      reported,
      isNot(contains('stranded')),
      reason:
          'a stale lease is exactly the slot the client must reclaim — '
          'reporting it would defeat the reconciliation',
    );
    expect(
      stale.existsSync(),
      isFalse,
      reason: 'and the sweep still reclaims it, as it did before',
    );
  });
}

String _esc(String s) => "'${s.replaceAll("'", r"'\''")}'";
