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

  test(
    'base-relative review is stable when current HEAD differs from base',
    () async {
      final baseOid = await raw(['rev-parse', 'refs/heads/main']);
      await raw(['checkout', '-q', '-b', 'feature']);
      await raw(['commit', '-q', '--allow-empty', '-m', 'feature-only']);
      final featureOid = await raw(['rev-parse', 'refs/heads/feature']);

      // Move HEAD to a third branch. Review must still compare the captured OIDs
      // above, not silently substitute the current branch.
      await raw(['checkout', '-q', '-b', 'other', 'refs/heads/main']);
      await raw(['commit', '-q', '--allow-empty', '-m', 'other-only']);
      expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'other');

      final result = await git.branchReviewSummaries(
        repo,
        baseOid: baseOid,
        branches: [
          (refName: 'refs/heads/feature', oid: featureOid),
          (refName: 'refs/heads/main', oid: baseOid),
        ],
      );
      final feature = result.summariesByRefName['refs/heads/feature']!;
      final main = result.summariesByRefName['refs/heads/main']!;
      expect((feature.aheadOfBase, feature.behindBase), (1, 0));
      expect(feature.mergedIntoBase, isFalse);
      expect((main.aheadOfBase, main.behindBase), (0, 0));
      expect(main.mergedIntoBase, isTrue);

      // mergedIntoBase must match git merge-base --is-ancestor for connected
      // histories (ahead==0 ⇔ branch tip is an ancestor of the base tip).
      Future<bool> isAncestor(String tip, String base) async {
        final r = await Process.run('git', [
          'merge-base',
          '--is-ancestor',
          tip,
          base,
        ], workingDirectory: repo);
        return r.exitCode == 0;
      }

      expect(await isAncestor(featureOid, baseOid), isFalse);
      expect(await isAncestor(baseOid, baseOid), isTrue);
      expect(feature.mergedIntoBase, await isAncestor(featureOid, baseOid));
      expect(main.mergedIntoBase, await isAncestor(baseOid, baseOid));
    },
  );

  test('renameBranch carries the upstream config across', () async {
    await git.renameBranch(repo, 'main', 'trunk');

    final upstream = await raw(['config', '--get', 'branch.trunk.merge']);
    expect(upstream, 'refs/heads/main', reason: 'tracking config followed');
    expect(
      await raw(['symbolic-ref', '--short', 'HEAD']),
      'trunk',
      reason: 'HEAD followed the rename of the current branch',
    );
  });

  test('deleteRemoteBranch removes the branch on the remote', () async {
    await raw(['checkout', '-q', '-b', 'doomed']);
    await raw(['push', '-q', '-u', 'origin', 'doomed']);
    await raw(['checkout', '-q', 'main']);
    expect(
      await raw(['branch', '--list', 'doomed'], cwd: origin),
      contains('doomed'),
    );

    await git.deleteRemoteBranch(repo, 'origin', 'doomed');

    expect(await raw(['branch', '--list', 'doomed'], cwd: origin), isEmpty);
    expect(
      await raw(['branch', '-r', '--list', 'origin/doomed']),
      isEmpty,
      reason: 'the local remote-tracking ref goes with it',
    );
  });

  test('a clone of an EMPTY remote reports its configured remote while '
      'having zero refs — the state the old refs-based "has remote" test '
      'misread as "No remote detected"', () async {
    final root = tempDir.resolveSymbolicLinksSync();
    final emptyOrigin = '$root/empty-origin';
    final emptyClone = '$root/empty-clone';
    await raw(['init', '-q', '--bare', emptyOrigin], cwd: root);
    await raw(['clone', '-q', emptyOrigin, emptyClone], cwd: root);

    expect(
      await git.remotes(emptyClone),
      ['origin'],
      reason: 'git remote is the config-level truth',
    );
    expect(
      await git.refs(emptyClone),
      isEmpty,
      reason: 'an empty clone has no refs of any kind',
    );
  });
}
