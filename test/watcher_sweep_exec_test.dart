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
    final pidFile = '${tmp.path}/mg-watch.pid';
    final proc = await spawnWatcher(pidFile);
    expect(await isAlive(proc.pid), isTrue, reason: 'fixture must be running');

    // No heartbeat file at all: the owner is gone, which is what an orphan is.
    await runScript(
      watcherSweepScript(
        [pidFile],
        heartbeat: '${tmp.path}/mg-watch.hb',
        staleAfter: const Duration(minutes: 5),
      ),
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

  test('the sweep spares a process that is not ours', () async {
    // A pid file naming a process whose command line carries no marker of
    // ours — a recycled pid, or another tool. Killing it would be the
    // "wrong processes in the kill set" failure 0025 records.
    final pidFile = '${tmp.path}/mg-watch.pid';
    final other = await Process.start('sh', ['-c', 'sleep 300']);
    spawned.add(other);
    File(pidFile).writeAsStringSync('${other.pid}');

    await runScript(
      watcherSweepScript(
        [pidFile],
        heartbeat: '${tmp.path}/mg-watch.hb',
        staleAfter: const Duration(minutes: 5),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      await isAlive(other.pid),
      isTrue,
      reason: 'a process that is not ours must never be signalled',
    );
  });
}

String _esc(String s) => "'${s.replaceAll("'", r"'\''")}'";
