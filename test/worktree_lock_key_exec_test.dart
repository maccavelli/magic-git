// MADR 0045 F10, executed. A linked worktree's `.git` is a FILE, so the host
// lock `mkdir <repo>/.git/mg-watch.lock` fails, and the script reads that as a
// lock another watcher holds: exit 98, every worktree refused. The lock has to
// live under the worktree's resolved git dir, which is a directory.
//
// Real `git`, real `sh`, the real generated script, and a shim `inotifywait`.
// Nothing here kills by name: the shim records its own PID, and only recorded
// PIDs that still carry this test's argv are killed (MADR 0045 plan, deviation
// (f)).
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';

const _marker = 'mg-worktree-lock-probe';

void main() {
  late Directory root;
  late String mainRepo;
  late String worktree;
  late String shimDir;
  final spawned = <Process>[];

  Future<String> git(List<String> args, String cwd) async {
    final r = await Process.run('git', args, workingDirectory: cwd);
    if (r.exitCode != 0) fail('git ${args.join(' ')} failed: ${r.stderr}');
    return (r.stdout as String).trim();
  }

  /// The shim watchers alive right now, by argv marker.
  Future<int> census() async {
    final r = await Process.run('sh', [
      '-c',
      'ps -eo args | grep -c "[m]g-worktree-lock-probe 300"',
    ]);
    return int.tryParse((r.stdout as String).trim()) ?? 0;
  }

  List<int> recordedPayloads() {
    final file = File('${root.path}/payload.pids');
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync()) ?int.tryParse(line.trim()),
    ];
  }

  /// SIGKILLs [pid] only while its argv still says it is this test's payload.
  Future<void> killOwnPayload(int pid) async {
    final r = await Process.run('ps', ['-o', 'args=', '-p', '$pid']);
    if ((r.stdout as String).trim().startsWith('$shimDir/$_marker')) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }

  setUp(() async {
    root = Directory(
      (await Directory.systemTemp.createTemp(
        'mg-worktree-lock-',
      )).resolveSymbolicLinksSync(),
    );
    mainRepo = '${root.path}/main';
    worktree = '${root.path}/feature';
    shimDir = '${root.path}/bin';
    Directory(mainRepo).createSync();
    Directory(shimDir).createSync();

    await git(['init', '-q', '-b', 'main'], mainRepo);
    await git(['config', 'user.email', 't@t'], mainRepo);
    await git(['config', 'user.name', 't'], mainRepo);
    await git(['config', 'commit.gpgsign', 'false'], mainRepo);
    File('$mainRepo/a.txt').writeAsStringSync('one\n');
    await git(['add', 'a.txt'], mainRepo);
    await git(['commit', '-q', '-m', 'first'], mainRepo);
    await git(['worktree', 'add', '-q', worktree, '-b', 'feature'], mainRepo);

    // The blocking payload, behind a marker-named symlink so its argv
    // identifies it; the shim records its own PID, which `exec` keeps.
    await Process.run('ln', ['-sf', '/bin/sleep', '$shimDir/$_marker']);
    File('$shimDir/inotifywait').writeAsStringSync(
      '#!/bin/sh\n'
      'echo \$\$ >> "${root.path}/payload.pids"\n'
      'exec "$shimDir/$_marker" 300\n',
    );
    await Process.run('chmod', ['+x', '$shimDir/inotifywait']);
  });

  tearDown(() async {
    // Closing stdin is the teardown under test elsewhere: the watchdog takes
    // the tree down. Then this test's own processes, then its own payloads.
    for (final p in spawned) {
      await p.stdin.close();
      await p.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    spawned.clear();
    for (final pid in recordedPayloads()) {
      await killOwnPayload(pid);
    }
    var noneLeft = false;
    for (var i = 0; i < 50 && !noneLeft; i++) {
      noneLeft = await census() == 0;
      if (!noneLeft) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (root.existsSync()) await root.delete(recursive: true);
    expect(noneLeft, isTrue, reason: 'a shim watcher outlived its test');
  });

  /// Starts the real recursive script against [gitDir], with its lease stamped
  /// (where the directory allows it) and stdin held open, as an SSH channel
  /// holds it.
  Future<({Process process, StringBuffer stderr})> arm(String gitDir) async {
    await Process.run('touch', ['$gitDir/mg-watch.t.hb']);
    final process = await Process.start(
      'sh',
      [
        '-c',
        recursiveWatchScript(
          inotify: true,
          excludes: '',
          pidFile: '$gitDir/mg-watch.t.pid',
          heartbeat: '$gitDir/mg-watch.t.hb',
          lock: (gitDir: gitDir, token: 't'),
        ),
      ],
      workingDirectory: worktree,
      environment: {'PATH': '$shimDir:${Platform.environment['PATH']}'},
    );
    spawned.add(process);
    final stderr = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    return (process: process, stderr: stderr);
  }

  test(
    'a worktree armed with its resolved git dir holds a live watcher',
    () async {
      final resolved = await git(['rev-parse', '--absolute-git-dir'], worktree);
      expect(
        resolved,
        contains('/.git/worktrees/'),
        reason: 'a linked worktree',
      );

      final armed = await arm(resolved);

      var marked = false;
      for (var i = 0; i < 50 && !marked; i++) {
        marked = armed.stderr.toString().contains(watchArmedMarker);
        if (!marked) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(marked, isTrue, reason: 'the arm announced itself');
      expect(
        await Process.run('kill', [
          '-0',
          '${armed.process.pid}',
        ]).then((r) => r.exitCode),
        0,
        reason: 'and the watcher is running',
      );
      expect(
        Directory('$resolved/mg-watch.lock').existsSync(),
        isTrue,
        reason: 'the lock was claimed under the resolved git dir',
      );
    },
  );

  test('a worktree armed with the conventional key is refused', () async {
    expect(
      FileSystemEntity.typeSync('$worktree/.git'),
      FileSystemEntityType.file,
      reason: 'the premise: a linked worktree\'s .git is a file',
    );

    final armed = await arm('$worktree/.git');
    final code = await armed.process.exitCode.timeout(
      const Duration(seconds: 10),
    );

    expect(
      code,
      boundedWatchLockedExit,
      reason:
          'the lock cannot be made under a file, and the script reads that as '
          'another watcher holding it — F10, every worktree refused',
    );
    expect(armed.stderr.toString(), isNot(contains(watchArmedMarker)));
  });
}
