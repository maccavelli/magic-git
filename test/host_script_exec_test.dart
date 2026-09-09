// MADR 0029 Phase 2: host scripts EXECUTED against real state.
//
// No `contains(...)` on script text in this file. Each test runs the script the
// app would send to a host and looks at what actually happened.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/git_cat_file_batch.dart';

Future<ProcessResult> _sh(String script, {String? cwd}) =>
    Process.run('sh', ['-c', script], workingDirectory: cwd);

void main() {
  late Directory repo;

  setUp(() async {
    repo = await Directory.systemTemp.createTemp('mg-catfile-');
    for (final args in [
      ['init', '-q'],
      ['config', 'user.email', 'test@example.invalid'],
      ['config', 'user.name', 'Test'],
      ['config', 'commit.gpgsign', 'false'],
    ]) {
      final r = await Process.run('git', args, workingDirectory: repo.path);
      expect(r.exitCode, 0, reason: 'git ${args.first} failed: ${r.stderr}');
    }
  });

  tearDown(() async {
    if (repo.existsSync()) await repo.delete(recursive: true);
  });

  /// Bytes that a lossy UTF-8 decode would destroy: a NUL, a lone 0xFF, and a
  /// truncated multi-byte sequence. This is exactly the content 0022 M10 was
  /// about — the batch parser frames objects by git's byte COUNT, so a single
  /// substituted byte desyncs every later object in the batch and returns the
  /// wrong content for the wrong key.
  final hostile = Uint8List.fromList([
    0x68,
    0x69,
    0x00,
    0xff,
    0xfe,
    0xc3,
    0x28,
    0x0a,
    0x00,
    0x80,
    0x7a,
  ]);

  test('cat-file batch returns exact bytes for binary content', () async {
    File('${repo.path}/bin.dat').writeAsBytesSync(hostile);
    File('${repo.path}/b.txt').writeAsStringSync('second object\n');
    for (final args in [
      ['add', '.'],
      ['commit', '-q', '-m', 'x'],
    ]) {
      final r = await Process.run('git', args, workingDirectory: repo.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    const specs = ['HEAD:bin.dat', 'HEAD:b.txt'];
    final res = await _sh(catFileBatchScript(specs), cwd: repo.path);
    expect(res.exitCode, 0, reason: 'script failed: ${res.stderr}');

    final raw = base64.decode((res.stdout as String).trim());
    final objects = parseCatFileBatch(raw, requests: specs);

    expect(objects, hasLength(2));
    expect(
      objects[0].content,
      orderedEquals(hostile),
      reason: 'byte-exact round trip — the whole point of the base64 hop',
    );
    // And the SECOND object is still correct, which is what desync destroys.
    expect(
      utf8.decode(objects[1].content!),
      'second object\n',
      reason: 'a desynced batch returns the wrong content for the wrong key',
    );
  });

  test('a missing object is reported as missing, not as wrong bytes', () async {
    File('${repo.path}/a.txt').writeAsStringSync('present\n');
    for (final args in [
      ['add', '.'],
      ['commit', '-q', '-m', 'x'],
    ]) {
      await Process.run('git', args, workingDirectory: repo.path);
    }

    const specs = ['HEAD:a.txt', 'HEAD:does-not-exist'];
    final res = await _sh(catFileBatchScript(specs), cwd: repo.path);
    expect(res.exitCode, 0);

    final objects = parseCatFileBatch(
      base64.decode((res.stdout as String).trim()),
      requests: specs,
    );
    expect(objects, hasLength(2));
    expect(utf8.decode(objects[0].content!), 'present\n');
    expect(
      objects[1].missing,
      isTrue,
      reason: 'the DECLINE direction: absence must not be served as content',
    );
  });

  test('the script fails loudly when git itself fails', () async {
    // Not a git repository: `git cat-file` exits non-zero, and the script must
    // surface that rather than the pipeline's last command's status. Piping
    // straight into base64 would report exit 0 with empty output — a silent
    // "no such object", which is the trap the temp file exists to avoid.
    final notARepo = await Directory.systemTemp.createTemp('mg-norepo-');
    addTearDown(() => notARepo.deleteSync(recursive: true));

    final res = await _sh(
      catFileBatchScript(const ['HEAD:whatever']),
      cwd: notARepo.path,
    );
    expect(
      res.exitCode,
      isNot(0),
      reason: 'a failed cat-file must not look like an empty success',
    );
  });

  // ---- the watcher lease loop, executed ---------------------------------
  //
  // `recursiveWatchScript` had NO test of any kind, and it is the script that
  // carried most of the 19 orphaned watchers found on the host. The watcher
  // binary is unavailable here, but the lease loop wrapped around it is pure
  // shell — so the real script text runs with an `inotifywait` shim ahead of it
  // on PATH. What is under test is the loop: does it record its pid, does it
  // arm while its lease is fresh, and does it give up when the lease is not.
  //
  // MADR 0041 reversed one contract here. The loop used to re-arm the watcher
  // on every `-t` wake, and a test asserted it did (`arms() > 1`). It now arms
  // ONCE and keeps that watch: the wake existed only so the shell could
  // re-check the lease, and a poll does that without tearing the watch down —
  // and a watcher that dies should reach the client's lifecycle engine rather
  // than being silently replaced on the host. The teardown behaviour the loop
  // gained (stdin EOF, the lease poll, the correct kill target) is executed in
  // watch_lease_teardown_exec_test.dart.

  group('watcher lease loop', () {
    late Directory dir;
    late String shimDir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mg-lease-');
      shimDir = '${dir.path}/bin';
      Directory(shimDir).createSync();
      // Counts its invocations, then blocks the way `inotifywait -m` does now
      // that nothing bounds it with `-t`.
      File('$shimDir/inotifywait').writeAsStringSync(
        '#!/bin/sh\n'
        'echo x >> "${dir.path}/arms"\n'
        'exec sleep 300\n',
      );
      await Process.run('chmod', ['+x', '$shimDir/inotifywait']);
      Directory('${dir.path}/.git').createSync();
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    int arms() => File('${dir.path}/arms').existsSync()
        ? File(
            '${dir.path}/arms',
          ).readAsLinesSync().where((l) => l.isNotEmpty).length
        : 0;

    String script() => recursiveWatchScript(
      inotify: true,
      excludes: '',
      pidFile: '${dir.path}/.git/mg-watch.t.pid',
      heartbeat: '${dir.path}/.git/mg-watch.t.hb',
    );

    Future<Process> run() => Process.start(
      'sh',
      ['-c', script()],
      workingDirectory: dir.path,
      environment: {'PATH': '$shimDir:${Platform.environment['PATH']}'},
    );

    test('gives up at once when its heartbeat file is absent', () async {
      // No lease file at all: the owner is gone before the loop starts.
      final p = await run();
      final code = await p.exitCode.timeout(const Duration(seconds: 10));
      expect(code, 0, reason: 'exits cleanly rather than watching forever');
      expect(arms(), 0, reason: 'and never armed the watcher at all');
    });

    test('gives up when its own lease has gone stale', () async {
      final hb = File('${dir.path}/.git/mg-watch.t.hb')..writeAsStringSync('');
      // Older than staleAfter (5 min) by any measure.
      await Process.run('touch', ['-t', '202001010000', hb.path]);
      final p = await run();
      final code = await p.exitCode.timeout(const Duration(seconds: 10));
      expect(code, 0);
      expect(arms(), 0, reason: 'the lease is checked BEFORE arming');
    });

    test('the bounded script arms only over paths that exist', () async {
      // `boundedInotifyScript` existence-guards each directory so one missing
      // path skips rather than aborting the whole watcher (a fresh repo has no
      // refs/tags yet). That guard is a behaviour, not a string.
      File('${dir.path}/.git/mg-watch.t.hb').writeAsStringSync('');
      Directory('${dir.path}/real').createSync();
      final p = await Process.start(
        'sh',
        [
          '-c',
          boundedInotifyScript(
            ['${dir.path}/real', '${dir.path}/does-not-exist'],
            pidFile: '${dir.path}/.git/mg-watch.t.pid',
            heartbeat: '${dir.path}/.git/mg-watch.t.hb',
          ),
        ],
        workingDirectory: dir.path,
        environment: {'PATH': '$shimDir:${Platform.environment['PATH']}'},
      );
      addTearDown(() => p.kill(ProcessSignal.sigkill));
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(
        arms(),
        greaterThan(0),
        reason:
            'a missing path must not stop the watcher arming over the '
            'ones that do exist',
      );
    });

    test('the fswatch form arms and honours the same lease', () async {
      // Same lease loop, different watcher binary. Shimmed the same way, so
      // the macOS-host path is exercised rather than assumed to match.
      File('$shimDir/fswatch').writeAsStringSync(
        '#!/bin/sh\necho x >> "${dir.path}/arms"\nsleep 0.2\nexit 0\n',
      );
      await Process.run('chmod', ['+x', '$shimDir/fswatch']);
      File('${dir.path}/.git/mg-watch.t.hb').writeAsStringSync('');
      Directory('${dir.path}/real').createSync();

      final p = await Process.start(
        'sh',
        [
          '-c',
          boundedFswatchScript(
            ['${dir.path}/real'],
            pidFile: '${dir.path}/.git/mg-watch.t.pid',
            heartbeat: '${dir.path}/.git/mg-watch.t.hb',
          ),
        ],
        workingDirectory: dir.path,
        environment: {'PATH': '$shimDir:${Platform.environment['PATH']}'},
      );
      addTearDown(() => p.kill(ProcessSignal.sigkill));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(arms(), greaterThan(0), reason: 'the fswatch arm ran');
    });

    test('records its pid and arms exactly once, keeping that watch', () async {
      // Was `arms() > 1`, reversed deliberately by MADR 0041 — see the group
      // comment. A second arm would mean the watch had been torn down and
      // re-walked, which is the cost this removed, and would also mean a
      // watcher death the client never heard about.
      File('${dir.path}/.git/mg-watch.t.hb').writeAsStringSync('');
      final p = await run();
      addTearDown(() => p.kill(ProcessSignal.sigkill));

      // Comfortably longer than the old 0.2 s re-arm cycle, so a loop that
      // still re-armed is caught rather than merely unobserved.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final pidFile = File('${dir.path}/.git/mg-watch.t.pid');
      expect(pidFile.existsSync(), isTrue, reason: 'the loop records its pid');
      final recorded = int.parse(pidFile.readAsStringSync().trim());
      final alive = await Process.run('kill', ['-0', '$recorded']);
      expect(alive.exitCode, 0, reason: 'the recorded pid is the live loop');

      expect(
        arms(),
        1,
        reason: 'the watch is established once and kept, never re-walked',
      );
    });
  });
}
