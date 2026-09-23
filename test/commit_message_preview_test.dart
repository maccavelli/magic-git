// MADR 0068 §A and Amendment 0068.1: the commit-message preview must leave
// nothing behind when it is killed, and must not orphan the hook it runs.
//
// These run the SHIPPED script text (`kCommitMessagePreviewScript`, not a
// retyped copy) under a real `sh` in a throwaway repository, and kill it the
// way both executors kill a timed-out command: SIGTERM to the `sh` process
// only, SIGKILL `SSHCommandExecutor.killGrace` later — never the process group
// (local_command_executor.dart `_killEscalate`, ssh_command_executor.dart
// `killAndCloseSession`). A probe that signalled the whole group once made a
// broken fix look correct (0068-PLAN deviation D1); this file must not repeat
// that.
//
// Every repository pins `core.hooksPath` to its own hooks directory: the
// machine running these tests may have a global hook that calls an AI provider,
// and a test that calls a provider is not a test.
//
// Real processes cannot run under `testWidgets`' fake async, so these are
// plain `test()`s, tagged `integration` like the repo's other real-git tests.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart'
    show kCommitMessagePreviewScript;
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart'
    show SSHCommandExecutor;

/// A hook that records its PID beside the message file (in the git dir),
/// then waits long enough to be killed mid-run.
const _slowHook = '''#!/bin/sh
echo \$\$ > "\$(dirname "\$1")/HOOK_PID"
sleep 30
echo "never written" > "\$1"
''';

/// Sends TERM, waits 50 µs, sends TERM again. The window in which a second
/// TERM defeats an unguarded cleanup is about 100 µs wide: sent together the
/// two merge into one pending signal, sent 200 µs apart the cleanup is already
/// done. Dart cannot time that; perl's `select` can (and this suite already
/// relies on perl — local_command_executor_test.dart).
const _doubleTerm =
    r'kill TERM => $ARGV[0]; '
    r'select undef, undef, undef, 0.00005; '
    r'kill TERM => $ARGV[0];';

/// A hook that writes a message at once.
const _fastHook = '''#!/bin/sh
echo "a generated message" > "\$1"
''';

/// A hook that talks on stderr (as the AI generator does: "generating via …",
/// retries) and on stdout, then writes its message.
const _chattyHook = '''#!/bin/sh
echo "generating via stub (model-x)..." >&2
echo "noise on stdout"
echo "retry 1 of 3" >&2
echo "a generated message" > "\$1"
''';

Future<void> _run(Directory cwd, List<String> args) async {
  final result = await Process.run(
    args.first,
    args.sublist(1),
    workingDirectory: cwd.path,
  );
  if (result.exitCode != 0) {
    fail('${args.join(' ')} failed: ${result.stderr}');
  }
}

/// A throwaway repository with [hook] as its `prepare-commit-msg`.
Future<Directory> _repoWithHook(String hook) async {
  final base = await Directory.systemTemp.createTemp('mg_preview_');
  final repo = Directory(base.resolveSymbolicLinksSync());
  addTearDown(() => repo.delete(recursive: true));
  await _run(repo, ['git', 'init', '-q']);
  // Never the machine's global hook — see the file header.
  await _run(repo, ['git', 'config', 'core.hooksPath', '.git/hooks']);
  final path = '${repo.path}/.git/hooks/prepare-commit-msg';
  await File(path).writeAsString(hook);
  await _run(repo, ['chmod', '755', path]);
  return repo;
}

List<String> _leftovers(Directory repo) => Directory('${repo.path}/.git')
    .listSync()
    .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
    .where((name) => name.startsWith('MAGICGIT_MSG_PREVIEW.'))
    .toList();

Future<bool> _alive(int pid) async =>
    (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;

Future<void> _waitFor(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!file.existsSync()) {
    if (DateTime.now().isAfter(deadline)) fail('${file.path} never appeared');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Process> _startPreview(Directory repo) => Process.start('sh', [
  '-c',
  kCommitMessagePreviewScript,
], workingDirectory: repo.path);

void main() {
  test('a preview killed like a timed-out command leaves no scratch file and '
      'no running hook', () async {
    final repo = await _repoWithHook(_slowHook);
    final process = await _startPreview(repo);
    final pidFile = File('${repo.path}/.git/HOOK_PID');
    await _waitFor(pidFile);
    final hookPid = int.parse(pidFile.readAsStringSync().trim());
    addTearDown(() => Process.run('kill', ['-9', '$hookPid']));

    // Exactly the executors' timeout path: TERM to sh, KILL after the grace.
    process.kill(ProcessSignal.sigterm);
    await Future<void>.delayed(SSHCommandExecutor.killGrace);
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      _leftovers(repo),
      isEmpty,
      reason: 'the killed preview must remove its scratch file',
    );
    expect(
      await _alive(hookPid),
      isFalse,
      reason:
          'the killed preview must not leave its hook running — an AI '
          'hook would keep calling its provider after the app gave up',
    );
  });

  test('a second TERM during cleanup does not cut the cleanup short', () async {
    // Anything may signal twice — the executor did until MADR 0068 Amendment
    // 0068.6, from a `finally`, microseconds after the first. A second TERM
    // re-entered the TERM trap while the EXIT trap was cleaning up, and its
    // `exit` ended the shell with the scratch file still in place. Repeated,
    // because the race is timed, not forced.
    for (var run = 0; run < 10; run++) {
      final repo = await _repoWithHook(_slowHook);
      final process = await _startPreview(repo);
      final pidFile = File('${repo.path}/.git/HOOK_PID');
      await _waitFor(pidFile);
      final hookPid = int.parse(pidFile.readAsStringSync().trim());
      addTearDown(() => Process.run('kill', ['-9', '$hookPid']));

      await _run(repo, ['perl', '-e', _doubleTerm, '${process.pid}']);
      await Future<void>.delayed(SSHCommandExecutor.killGrace);
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(_leftovers(repo), isEmpty, reason: 'run $run left its file');
      expect(await _alive(hookPid), isFalse, reason: 'run $run left its hook');
    }
  });

  test(
    'a preview that completes leaves nothing and returns the message',
    () async {
      final repo = await _repoWithHook(_fastHook);
      final process = await _startPreview(repo);
      final stdout = await process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      expect(await process.exitCode, 0);
      expect(stdout.trim(), 'a generated message');
      expect(_leftovers(repo), isEmpty);
    },
  );

  // MADR Amendment 0068.2: the hook's stderr reaches the caller's stderr, live,
  // so the executor's onOutput can stream it to the Output view; its stdout
  // stays discarded so it can never contaminate the message.
  test(
    'the hook\'s stderr reaches the caller; the message stays clean',
    () async {
      final repo = await _repoWithHook(_chattyHook);
      final process = await _startPreview(repo);
      final stdout = process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final stderr = process.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      expect(await process.exitCode, 0);

      expect(
        await stdout,
        'a generated message\n',
        reason: 'stdout is the message file and nothing else',
      );
      final err = await stderr;
      expect(err, contains('generating via stub (model-x)...'));
      expect(err, contains('retry 1 of 3'));
      expect(
        err,
        isNot(contains('noise on stdout')),
        reason: 'the hook\'s own stdout is not the message and is dropped',
      );
    },
  );

  test('a leftover older than a day is swept', () async {
    final repo = await _repoWithHook(_fastHook);
    final stale = File('${repo.path}/.git/MAGICGIT_MSG_PREVIEW.stale')
      ..writeAsStringSync('');
    stale.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));

    final process = await _startPreview(repo);
    await process.stdout.drain<void>();
    expect(await process.exitCode, 0);

    expect(
      stale.existsSync(),
      isFalse,
      reason: 'what a SIGKILL left behind is collected by the next preview',
    );
  });

  test('a fresh leftover — a concurrent preview — is not swept', () async {
    final repo = await _repoWithHook(_fastHook);
    final fresh = File('${repo.path}/.git/MAGICGIT_MSG_PREVIEW.fresh')
      ..writeAsStringSync('');

    final process = await _startPreview(repo);
    await process.stdout.drain<void>();
    expect(await process.exitCode, 0);

    expect(
      fresh.existsSync(),
      isTrue,
      reason: 'another tab may be previewing right now',
    );
  });
}
