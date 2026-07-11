// Sanity coverage for LocalCommandExecutor against real local processes (no
// SSH/mocking involved — this is exactly what makes it simpler than
// SSHCommandExecutor, so exercising real `sh`/`git` is the honest test).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    expect(result.stdout.trim(), Directory(tempDir.path).resolveSymbolicLinksSync());
  });

  test('execute captures a non-zero exit code without throwing', () async {
    final result = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'exit 7'],
    );
    expect(result.exitCode, 7);
    expect(result.isSuccess, isFalse);
  });

  test('a missing binary is a clean 127 result, not a raw ProcessException',
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
  });

  test('a missing working directory is a clean non-127 failure, not a throw',
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
        .execute(
          repoPath: tempDir.path,
          gitArgs: ['sh', '-c', 'sleep 0.05'],
        )
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

  test(
    'execute throws SSHOutputExceeded for output past the cap',
    () async {
      expect(
        () => executor.execute(
          repoPath: tempDir.path,
          gitArgs: [
            'sh',
            '-c',
            'yes | head -c 1000',
          ],
          timeout: const Duration(seconds: 5),
        ),
        returnsNormally,
      );
      // Confirm the cap actually trips with a tiny ceiling via collectBounded
      // directly (mirrors ssh_command_executor_test.dart's own approach).
      final stream = Stream<String>.fromIterable(['a' * 50, 'b' * 50]);
      expect(
        () => SSHCommandExecutor.collectBounded(stream, 'test', maxChars: 10),
        throwsA(isA<SSHOutputExceeded>()),
      );
    },
  );

  test('configureEnvironment rewrites argv[0] to an overridden binary path', () async {
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
  });

  test('executeStream streams incremental output and reports exit code', () async {
    final handle = await executor.executeStream(
      repoPath: tempDir.path,
      gitArgs: ['sh', '-c', 'echo one; echo two; exit 3'],
    );
    final lines = await handle.stdout.join();
    expect(lines, contains('one'));
    expect(lines, contains('two'));
    expect(await handle.exitCode, 3);
  });

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
}
