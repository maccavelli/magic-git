// Branch operations against real git with a real (file-protocol) remote:
// the %(upstream:track) divergence fields, rename carrying config across,
// and remote-branch deletion. The unit tests pin the argv; only real git can
// pin what the argv MEANS.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tempDir;
  late String origin;
  late String repo;
  late GitService git;

  Future<String> raw(List<String> args, {String? cwd}) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: cwd ?? repo,
    );
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('branch_ops_');
    final root = tempDir.resolveSymbolicLinksSync();
    origin = '$root/origin';
    repo = '$root/repo';
    Directory(origin).createSync(recursive: true);
    git = GitService(LocalCommandExecutor());

    await raw(['init', '-q', '-b', 'main'], cwd: origin);
    await raw(['config', 'user.name', 'T'], cwd: origin);
    await raw(['config', 'user.email', 't@t'], cwd: origin);
    await raw(['commit', '-q', '--allow-empty', '-m', 'one'], cwd: origin);
    await raw(['commit', '-q', '--allow-empty', '-m', 'two'], cwd: origin);
    await raw(['clone', '-q', origin, repo], cwd: root);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('refs report ahead/behind divergence and a gone upstream', () async {
    // Diverge main: drop one upstream commit, add two local ones.
    await raw(['reset', '-q', '--hard', 'HEAD~1']);
    await raw(['commit', '-q', '--allow-empty', '-m', 'local-a']);
    await raw(['commit', '-q', '--allow-empty', '-m', 'local-b']);
    // And manufacture a gone upstream: push a branch, delete it on the
    // remote, prune.
    await raw(['checkout', '-q', '-b', 'stale']);
    await raw(['push', '-q', '-u', 'origin', 'stale']);
    await raw(['branch', '-D', 'stale'], cwd: origin);
    await raw(['fetch', '-q', '--prune']);
    await raw(['checkout', '-q', 'main']);

    final refs = await git.refs(repo);
    final main = refs.singleWhere((r) => r.name == 'refs/heads/main');
    final stale = refs.singleWhere((r) => r.name == 'refs/heads/stale');

    expect((main.ahead, main.behind), (2, 1));
    expect(main.upstreamGone, isFalse);
    expect(stale.upstreamGone, isTrue);
  });

  test('renameBranch carries the upstream config across', () async {
    await git.renameBranch(repo, 'main', 'trunk');

    final upstream = await raw([
      'config',
      '--get',
      'branch.trunk.merge',
    ]);
    expect(upstream, 'refs/heads/main', reason: 'tracking config followed');
    expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'trunk',
        reason: 'HEAD followed the rename of the current branch');
  });

  test('deleteRemoteBranch removes the branch on the remote', () async {
    await raw(['checkout', '-q', '-b', 'doomed']);
    await raw(['push', '-q', '-u', 'origin', 'doomed']);
    await raw(['checkout', '-q', 'main']);
    expect(await raw(['branch', '--list', 'doomed'], cwd: origin),
        contains('doomed'));

    await git.deleteRemoteBranch(repo, 'origin', 'doomed');

    expect(await raw(['branch', '--list', 'doomed'], cwd: origin), isEmpty);
    expect(
      await raw(['branch', '-r', '--list', 'origin/doomed']),
      isEmpty,
      reason: 'the local remote-tracking ref goes with it',
    );
  });
}
