// Safe Redo feasibility against real git. The supported surface is purposely
// only tag-ref compare-and-swap operations; these tests prove unrelated HEAD,
// branch, index, worktree, and stash-list changes survive, while an external
// process changing the target tag makes replay stale without overwriting it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

void main() {
  late Directory tempDir;
  late String repo;
  late List<UndoRecord> records;
  late GitService git;

  Future<String> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  Future<void> write(String name, String content) =>
      File('$repo/$name').writeAsString(content);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('redo_scripts_test_');
    repo = tempDir.path;
    records = [];
    git = GitService(LocalCommandExecutor(), onUndoRecord: records.add);
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Test']);
    await raw(['config', 'user.email', 'test@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await write('base.txt', 'base\n');
    await write('index.txt', 'base\n');
    await write('worktree.txt', 'base\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'base']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test(
    'redoing tag creation restores the exact annotated tag object',
    () async {
      await git.createTag(repo, 'v1', message: 'release notes');
      final undo = records.single;
      final tagObject = undo.deletedOid;

      await git.undoExecute(undo);
      final redo = RedoRecord.afterSuccessfulUndo(undo)!;
      await git.redoExecute(redo);

      expect(await raw(['rev-parse', 'refs/tags/v1']), tagObject);
      expect(await raw(['cat-file', '-t', 'refs/tags/v1']), 'tag');
    },
  );

  test('tag-delete redo ignores unrelated repository state changes', () async {
    await raw(['tag', '-a', '-m', 'release notes', 'v1']);
    await git.deleteTag(repo, 'v1');
    final undo = records.single;
    await git.undoExecute(undo);
    final redo = RedoRecord.afterSuccessfulUndo(undo)!;

    // All repository dimensions named by the feasibility gate change after
    // undo, but none is read or written by the tag-ref transaction.
    await write('head.txt', 'new head\n');
    await raw(['add', 'head.txt']);
    await raw(['commit', '-q', '-m', 'external head move']);
    final head = await raw(['rev-parse', 'HEAD']);
    await raw(['branch', 'external-branch']);
    final branch = await raw(['rev-parse', 'refs/heads/external-branch']);
    await write('stash.txt', 'stash payload\n');
    await raw(['stash', 'push', '-q', '-u', '-m', 'external stash']);
    final stash = await raw(['rev-parse', 'stash@{0}']);
    await write('index.txt', 'staged after undo\n');
    await raw(['add', 'index.txt']);
    await write('worktree.txt', 'unstaged after undo\n');
    final status = await raw(['status', '--porcelain']);

    await git.redoExecute(redo);

    final tagProbe = await Process.run('git', [
      'rev-parse',
      '-q',
      '--verify',
      'refs/tags/v1',
    ], workingDirectory: repo);
    expect(tagProbe.exitCode, isNot(0));
    expect(await raw(['rev-parse', 'HEAD']), head);
    expect(await raw(['rev-parse', 'refs/heads/external-branch']), branch);
    expect(await raw(['rev-parse', 'stash@{0}']), stash);
    expect(await raw(['status', '--porcelain']), status);
  });

  test('external tag creation makes create replay stale atomically', () async {
    await git.createTag(repo, 'v1', message: 'original');
    final undo = records.single;
    await git.undoExecute(undo);
    final redo = RedoRecord.afterSuccessfulUndo(undo)!;

    await write('base.txt', 'external\n');
    await raw(['commit', '-qam', 'external commit']);
    await raw(['tag', '-a', '-m', 'external tag', 'v1']);
    final externalOid = await raw(['rev-parse', 'refs/tags/v1']);

    await expectLater(
      () => git.redoExecute(redo),
      throwsA(isA<RedoStaleException>()),
    );
    expect(await raw(['rev-parse', 'refs/tags/v1']), externalOid);
  });

  test('external tag move makes delete replay stale atomically', () async {
    await raw(['tag', 'v1']);
    await git.deleteTag(repo, 'v1');
    final undo = records.single;
    await git.undoExecute(undo);
    final redo = RedoRecord.afterSuccessfulUndo(undo)!;

    await write('base.txt', 'external\n');
    await raw(['commit', '-qam', 'external commit']);
    await raw(['tag', '-f', 'v1']);
    final externalOid = await raw(['rev-parse', 'refs/tags/v1']);

    await expectLater(
      () => git.redoExecute(redo),
      throwsA(isA<RedoStaleException>()),
    );
    expect(await raw(['rev-parse', 'refs/tags/v1']), externalOid);
  });
}
