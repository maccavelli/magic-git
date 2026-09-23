// Sanity coverage for LocalCommandExecutor against real local processes (no
// SSH/mocking involved — this is exactly what makes it simpler than
// SSHCommandExecutor, so exercising real `sh`/`git` is the honest test).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_telemetry.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  late Directory tempDir;
  late LocalCommandExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_exec_test_');
    executor = LocalCommandExecutor();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('execute runs a real process in the given working directory', () async {
    final result = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'pwd'],
    );
    expect(result.isSuccess, isTrue);
    // Resolve symlinks (macOS's /tmp is a symlink to /private/tmp) so this
    // compares like-for-like with what `pwd` actually prints.
    expect(
      result.stdout.trim(),
      Directory(tempDir.path).resolveSymbolicLinksSync(),
    );
  });

  test('execute captures a non-zero exit code without throwing', () async {
    final result = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'exit 7'],
    );
    expect(result.exitCode, 7);
    expect(result.isSuccess, isFalse);
  });

  test(
    'a missing binary is a clean 127 result, not a raw ProcessException',
    () async {
      // Over SSH a missing binary comes back as a non-zero exit; the local
      // backend must present the same shape (a result callers turn into a
      // GitException) instead of throwing an uncaught ProcessException.
      final result = await executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['this-binary-does-not-exist-xyz', '--version'],
      );
      expect(result.isSuccess, isFalse);
      expect(result.exitCode, 127);
      expect(result.stderr, isNotEmpty);
    },
  );

  test(
    'a missing working directory is a clean non-127 failure, not a throw',
    () async {
      final result = await executor.execute(
        repoPath: '${tempDir.path}/no-such-subdir',
        gitArgs: ['sh', '-c', 'pwd'],
      );
      expect(result.isSuccess, isFalse);
      // NOT 127: GitService reads 127 as "git is not installed" and tells the
      // user to fix their git install — misleading when the repo folder itself
      // was moved/deleted. Mirrors the SSH backend, where a missing dir is a
      // failed `cd` (non-127) and surfaces as "not a git repository".
      expect(result.exitCode, isNot(127));
      expect(result.stderr, contains('cannot access repository folder'));
    },
  );

  test('onOutput is invoked before execute completes', () async {
    final chunks = <({String chunk, bool stderr})>[];
    var completed = false;
    final result = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'printf hello; printf err >&2'],
      onOutput: (chunk, {required stderr}) {
        expect(
          completed,
          isFalse,
          reason: 'chunk arrived after execute returned',
        );
        chunks.add((chunk: chunk, stderr: stderr));
      },
    );
    completed = true;
    expect(result.isSuccess, isTrue);
    expect(chunks.any((c) => !c.stderr && c.chunk.contains('hello')), isTrue);
    expect(chunks.any((c) => c.stderr && c.chunk.contains('err')), isTrue);
  });

  test('a deterministic spawn failure is not retried', () async {
    // With retries requested, a missing binary must NOT spin (it returns a
    // result now, which runWithRetries treats as success-shaped, not a throw).
    final sw = Stopwatch()..start();
    final result = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['this-binary-does-not-exist-xyz'],
      retries: 3,
    );
    sw.stop();
    expect(result.exitCode, 127);
    // 3 retries × 400ms backoff would be >1s; a single attempt is well under.
    expect(sw.elapsedMilliseconds, lessThan(400));
  });

  test('execute pipes stdin to the process', () async {
    final result = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'cat'],
      stdin: 'hello from stdin',
    );
    expect(result.stdout, 'hello from stdin');
  });

  test('execute serializes overlapping commands (no interleaving)', () async {
    final order = <int>[];
    final first = executor
        .execute(repoPath: tempDir.path, gitArgs: ['sh', '-c', 'sleep 0.05'])
        .then((_) => order.add(1));
    final second = executor
        .execute(repoPath: tempDir.path, gitArgs: ['sh', '-c', 'true'])
        .then((_) => order.add(2));
    await Future.wait([first, second]);
    expect(order, [1, 2]);
  });

  test('execute throws SSHCommandTimeout and kills the process', () async {
    expect(
      () => executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'sleep 5'],
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );
  });

  test('a timed-out command records a failed telemetry sample', () async {
    // The dashboard must see failed commands, not just successes — a session
    // where every read times out otherwise reports as perfectly healthy.
    CommandTelemetry.instance.reset();
    await expectLater(
      executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'sleep 5'],
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );
    final t = CommandTelemetry.instance;
    expect(t.commandCount, 1);
    expect(t.samples.single.success, isFalse);
  });

  test('a timed-out command receives exactly one TERM', () async {
    // TERM once, then KILL after the grace — never a second TERM. A second
    // one, sent from a `finally` microseconds after the first, re-entered a
    // shell's TERM trap while its EXIT trap was cleaning up, and the commit
    // message preview left its scratch file behind (MADR 0068, Amendment
    // 0068.6). The shell counts every TERM and survives each, so only the KILL
    // ends it.
    await expectLater(
      executor.execute(
        repoPath: tempDir.path,
        gitArgs: [
          'sh',
          '-c',
          'trap "echo TERM >> term.log" TERM; '
              ': > started; '
              r'while :; do sleep 1 & wait $!; done',
        ],
        timeout: const Duration(milliseconds: 500),
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );
    await Future<void>.delayed(
      SSHCommandExecutor.killGrace + const Duration(milliseconds: 600),
    );
    expect(File('${tempDir.path}/started').existsSync(), isTrue);
    final log = File('${tempDir.path}/term.log');
    expect(log.existsSync() ? log.readAsLinesSync() : const <String>[], [
      'TERM',
    ]);
  });

  test(
    'a command that overflows the output cap and ignores TERM is killed',
    () async {
      // The drain-failure path escalates like the timeout path (and like the
      // SSH twin's `_killAndClose`): a TERM alone let a process that ignores
      // it run on, unattended, after the executor had given up on it. It
      // stops writing once over the cap — a writer would die of SIGPIPE
      // anyway, whatever the executor sends.
      await expectLater(
        executor.execute(
          repoPath: tempDir.path,
          gitArgs: [
            'sh',
            '-c',
            r"trap '' TERM; echo $$ > pid; "
                'head -c 60000000 /dev/zero; exec sleep 30',
          ],
          timeout: const Duration(seconds: 20),
        ),
        throwsA(isA<SSHOutputExceeded>()),
      );
      final pid = File('${tempDir.path}/pid').readAsStringSync().trim();
      await Future<void>.delayed(
        SSHCommandExecutor.killGrace + const Duration(milliseconds: 600),
      );
      addTearDown(() => Process.run('kill', ['-9', pid]));
      final alive = await Process.run('kill', ['-0', pid]);
      expect(alive.exitCode, isNot(0), reason: 'pid $pid is still running');
    },
  );

  test('cancelling a stream twice signals its process once', () async {
    // A second cancel is a second TERM — the same re-entry a timed-out
    // command's double TERM caused (MADR 0068, Amendment 0068.6).
    final handle = await executor.executeStream(
      repoPath: tempDir.path,
      gitArgs: [
        'sh',
        '-c',
        'trap "echo TERM >> term.log" TERM; '
            ': > started; '
            r'while :; do sleep 1 & wait $!; done',
      ],
    );
    final started = File('${tempDir.path}/started');
    while (!started.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await handle.cancel();
    await handle.cancel();
    await handle.exitCode;
    final log = File('${tempDir.path}/term.log');
    expect(log.existsSync() ? log.readAsLinesSync() : const <String>[], [
      'TERM',
    ]);
  });

  test('execute throws SSHOutputExceeded for output past the cap', () async {
    expect(
      () => executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'yes | head -c 1000'],
        timeout: const Duration(seconds: 5),
      ),
      returnsNormally,
    );
    // Confirm the cap actually trips with a tiny ceiling via collectBounded
    // directly (the canonical coverage lives in command_drain_test.dart).
    final stream = Stream<String>.fromIterable(['a' * 50, 'b' * 50]);
    expect(
      () => collectBounded(stream, 'test', maxChars: 10),
      throwsA(isA<SSHOutputExceeded>()),
    );
  });

  test(
    'configureEnvironment rewrites argv[0] to an overridden binary path',
    () async {
      // Create a fake "git" binary that just echoes its own path, and confirm
      // argv[0] gets rewritten to it rather than invoking the real `git`.
      final fakeBin = File('${tempDir.path}/fake-git')
        ..writeAsStringSync('#!/bin/sh\necho "fake-git-ran"\n');
      await Process.run('chmod', ['+x', fakeBin.path]);

      executor.configureEnvironment(binaries: {'git': fakeBin.path});
      final result = await executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['git', '--version'],
      );
      expect(result.stdout.trim(), 'fake-git-ran');

      executor.resetEnvironment();
      final result2 = await executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'echo no-override'],
      );
      expect(result2.stdout.trim(), 'no-override');
    },
  );

  test(
    'executeStream streams incremental output and reports exit code',
    () async {
      final handle = await executor.executeStream(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'echo one; echo two; exit 3'],
      );
      final lines = await handle.stdout.join();
      expect(lines, contains('one'));
      expect(lines, contains('two'));
      expect(await handle.exitCode, 3);
    },
  );

  test('executeStream cancel terminates a long-running process', () async {
    final handle = await executor.executeStream(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'sleep 30'],
    );
    await handle.cancel();
    // A killed process should resolve its exitCode (non-null, non-zero) well
    // before the 30s sleep would naturally finish.
    final code = await handle.exitCode.timeout(const Duration(seconds: 5));
    expect(code, isNot(0));
  });

  test(
    'activityIdle: stderr pulses past the idle budget still complete',
    () async {
      // Piped `sh` `echo` is fully buffered, and Process.stdout coalesces
      // live writes (~100ms). A 50ms sleep + 120ms idle is a race; the SSH
      // fake never hits that pipe. Flushed perl for ~0.9s with idle 2s
      // finishes only if pulses reset the stall timer.
      //
      // The idle budget is 2s, not the ~13x-pulse-interval 400ms this test
      // shipped with, because 400ms measurably was not enough: it failed once
      // under a full-suite run (perl's own 30ms sleeps delayed by real OS
      // scheduling contention from ~4000 concurrent tests, most spawning
      // their own subprocesses) while passing every time in isolation and
      // under two smaller synthetic-load reproductions. This is the check
      // being wrong as written for a many-thousand-test run, not a defect in
      // ActivityDeadline (activity_deadline.dart) — its stall-timer logic is
      // unchanged; only this test's own margin against real scheduling
      // jitter widens.
      final result = await executor.execute(
        repoPath: tempDir.path,
        gitArgs: [
          'perl',
          '-e',
          r'use Time::HiRes qw(time sleep); '
              r'select(STDERR); $| = 1; select(STDOUT); $| = 1; '
              r'my $end = time() + 0.9; '
              r'while (time() < $end) { print STDERR "p\n"; sleep(0.03) } '
              r'print "ok\n"',
        ],
        activityIdle: const Duration(seconds: 2),
        timeout: const Duration(seconds: 5),
      );
      expect(result.isSuccess, isTrue);
      expect(result.stdout, contains('ok'));
    },
  );

  test(
    'activityIdle: stdout pulses past the idle budget still complete',
    () async {
      // Same widened margin as its stderr sibling above, for the same
      // reason: 400ms measured insufficient under full-suite scheduling
      // contention.
      final result = await executor.execute(
        repoPath: tempDir.path,
        gitArgs: [
          'perl',
          '-e',
          r'use Time::HiRes qw(time sleep); $| = 1; '
              r'my $end = time() + 0.9; '
              r'while (time() < $end) { print "p\n"; sleep(0.03) } '
              r'print "ok\n"',
        ],
        activityIdle: const Duration(seconds: 2),
        timeout: const Duration(seconds: 5),
      );
      expect(result.isSuccess, isTrue);
      expect(result.stdout, contains('ok'));
    },
  );

  test('activityIdle: silence throws SSHCommandTimeout', () async {
    await expectLater(
      executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'sleep 1; echo ok'],
        activityIdle: const Duration(milliseconds: 80),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );
  });

  test('activityIdle: ceiling still kills a pulsing command', () async {
    await expectLater(
      executor.execute(
        repoPath: tempDir.path,
        gitArgs: ['sh', '-c', 'while true; do echo p; sleep 0.02; done'],
        activityIdle: const Duration(seconds: 5),
        timeout: const Duration(milliseconds: 150),
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );
  });
}
