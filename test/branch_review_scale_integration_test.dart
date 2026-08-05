// Phase 7: ordinary (non-live-forge) scale fixture — 500 local tips with
// divergent histories. Asserts batching shape of review summaries against real
// git, not wall-clock timing.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tempDir;
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
    tempDir = Directory.systemTemp.createTempSync('branch_scale_');
    repo = tempDir.resolveSymbolicLinksSync();
    git = GitService(LocalCommandExecutor());
    await raw(['init', '-q', '-b', 'main'], cwd: repo);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);
    File('$repo/base.txt').writeAsStringSync('base\n');
    await raw(['add', 'base.txt']);
    await raw(['commit', '-q', '-m', 'base']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test(
    '500 local branches: review summaries return without worktree mutation',
    () async {
      // Create many short-lived branches with divergent empty commits.
      // Cap wall time: empty commits are cheap; 500 is the plan floor.
      const n = 500;
      for (var i = 0; i < n; i++) {
        await raw(['checkout', '-q', '-b', 'feature/$i', 'main']);
        await raw(['commit', '-q', '--allow-empty', '-m', 'f$i']);
      }
      await raw(['checkout', '-q', 'main']);
      final baseOid = await raw(['rev-parse', 'main']);
      final headBefore = await raw(['rev-parse', 'HEAD']);
      final statusBefore = await raw(['status', '--porcelain=v2', '-z']);

      final refs = await git.refs(repo);
      final locals = [
        for (final r in refs)
          if (r.isLocalBranch && !r.isHead)
            (refName: r.name, oid: r.commitOid),
      ];
      expect(locals.length, greaterThanOrEqualTo(n));

      final result = await git.branchReviewSummaries(
        repo,
        baseOid: baseOid,
        branches: locals,
      );
      expect(result.summariesByRefName.length, greaterThanOrEqualTo(n));
      // Every tip should report ahead of base (one empty commit each).
      expect(
        result.summariesByRefName.values.every((s) => s.aheadOfBase >= 1),
        isTrue,
      );

      // Batches: ceil(n / batchSize) host invocations is the production shape;
      // assert the constant still yields a multi-batch plan for this n.
      const planned =
          (n + GitService.branchReviewBatchSize - 1) ~/
          GitService.branchReviewBatchSize;
      expect(planned, greaterThanOrEqualTo(5));

      expect(await raw(['rev-parse', 'HEAD']), headBefore);
      expect(await raw(['status', '--porcelain=v2', '-z']), statusBefore);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
