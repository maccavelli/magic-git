// Real git: merge-tree preview must not touch HEAD, refs, index, or worktree.
// Object count may grow (unreachable trees) — that is not a failure.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
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

  Future<int> objectCount() async {
    final result = await Process.run(
      'git',
      ['count-objects', '-v'],
      workingDirectory: repo,
    );
    expect(result.exitCode, 0);
    for (final line in (result.stdout as String).split('\n')) {
      if (line.startsWith('count:')) {
        return int.parse(line.split(':').last.trim());
      }
    }
    return -1;
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('merge_preview_');
    repo = tempDir.resolveSymbolicLinksSync();
    git = GitService(LocalCommandExecutor());
    await raw(['init', '-q', '-b', 'main'], cwd: repo);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);
    File('$repo/f.txt').writeAsStringSync('base\n');
    await raw(['add', 'f.txt']);
    await raw(['commit', '-q', '-m', 'base']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('clean merge prediction leaves HEAD/index/worktree unchanged', () async {
    await raw(['checkout', '-q', '-b', 'feat']);
    File('$repo/only-feat.txt').writeAsStringSync('feat\n');
    await raw(['add', 'only-feat.txt']);
    await raw(['commit', '-q', '-m', 'feat only']);
    await raw(['checkout', '-q', 'main']);
    File('$repo/only-main.txt').writeAsStringSync('main\n');
    await raw(['add', 'only-main.txt']);
    await raw(['commit', '-q', '-m', 'main only']);

    final baseOid = await raw(['rev-parse', 'main']);
    final branchOid = await raw(['rev-parse', 'feat']);
    final headBefore = await raw(['rev-parse', 'HEAD']);
    final statusBefore = await raw(['status', '--porcelain=v2', '-z']);
    final countBefore = await objectCount();

    final preview = await git.mergeTreePreview(
      repo,
      baseOid: baseOid,
      branchOid: branchOid,
    );
    expect(preview.state, MergePreviewState.clean);
    expect(preview.treeOid, isNotNull);

    expect(await raw(['rev-parse', 'HEAD']), headBefore);
    expect(await raw(['status', '--porcelain=v2', '-z']), statusBefore);
    // Object count may grow from the written merge tree — document, not fail.
    final countAfter = await objectCount();
    expect(countAfter, greaterThanOrEqualTo(countBefore));
  });

  test('conflicting tips report paths without mutating the worktree', () async {
    await raw(['checkout', '-q', '-b', 'feat']);
    File('$repo/f.txt').writeAsStringSync('feat\n');
    await raw(['add', 'f.txt']);
    await raw(['commit', '-q', '-m', 'feat edit']);
    await raw(['checkout', '-q', 'main']);
    File('$repo/f.txt').writeAsStringSync('main\n');
    await raw(['add', 'f.txt']);
    await raw(['commit', '-q', '-m', 'main edit']);

    final baseOid = await raw(['rev-parse', 'main']);
    final branchOid = await raw(['rev-parse', 'feat']);
    final headBefore = await raw(['rev-parse', 'HEAD']);
    final statusBefore = await raw(['status', '--porcelain=v2', '-z']);

    final preview = await git.mergeTreePreview(
      repo,
      baseOid: baseOid,
      branchOid: branchOid,
    );
    expect(preview.state, MergePreviewState.conflicts);
    expect(preview.conflictPaths, contains('f.txt'));
    expect(await raw(['rev-parse', 'HEAD']), headBefore);
    expect(await raw(['status', '--porcelain=v2', '-z']), statusBefore);
  });
}
