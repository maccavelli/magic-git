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

/// A hook that writes a message at once.
const _fastHook = '''#!/bin/sh
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
