// Stash operations against real git — what the argv pins can't prove:
// that the stale-OID guard actually refuses a shifted list, that OID
// addressing survives shifts entirely, and that the preview really shows
// untracked content.
@Tags(['integration'])
library;

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

  /// Edits the tracked file and stashes, returning the new list.
  Future<List<GitStash>> pushStash(String marker, {String? message}) async {
    await write('f.txt', '$marker\n');
    await raw([
      'stash',
      'push',
      '-q',
      if (message != null) ...['-m', message],
    ]);
    return git.stashList(repo);
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('stash_ops_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    records = [];
    git = GitService(LocalCommandExecutor(), onUndoRecord: records.add);
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await write('f.txt', 'base\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'base']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('a drop aimed at a shifted list is refused — nothing dropped', () async {
    final rendered = (await pushStash('alpha', message: 'alpha')).single;
    // The list shifts AFTER the UI rendered it: a new stash lands on top.
    await pushStash('beta', message: 'beta');

    await expectLater(
      git.stashDrop(repo, rendered.index, expectedOid: rendered.oid),
      throwsA(isA<StashStaleException>()),
    );
    expect(
      await git.stashList(repo),
      hasLength(2),
      reason: 'the guard must leave every stash in place',
    );
  });

  test(
    'a drop aimed at a current list drops exactly that stash, undoably',
    () async {
      await pushStash('alpha', message: 'alpha');
      final list = await pushStash('beta', message: 'beta');
      final beta = list.singleWhere((s) => s.message.contains('beta'));

      await git.stashDrop(repo, beta.index, expectedOid: beta.oid);

      final after = await git.stashList(repo);
      expect(after.single.message, contains('alpha'));

      // And the drop journaled: undo brings beta back.
      await git.undoExecute(records.single);
      expect(await git.stashList(repo), hasLength(2));
    },
  );

  test('pop undo un-applies the changes AND re-stores the entry', () async {
    final entry = (await pushStash('alpha', message: 'alpha')).single;

    await git.stashPop(repo, entry.index, expectedOid: entry.oid);
    expect(await git.stashList(repo), isEmpty);
    expect(
      await File('$repo/f.txt').readAsString(),
      'alpha\n',
      reason: 'popped content applied',
    );

    expect(records.single.kind, UndoOpKind.stashPop);
    await git.undoExecute(records.single);
    // Path (a): a clean reversal — the applied changes are gone from the tree
    // (not left duplicated as the old stash-store-only undo did) and the entry
    // is back.
    expect(
      await File('$repo/f.txt').readAsString(),
      'base\n',
      reason: 'the popped changes were un-applied',
    );
    expect(
      await git.stashList(repo),
      hasLength(1),
      reason: 'the stash entry itself is back',
    );
  });

  test(
    'pop undo keeps an unrelated change that was present before the pop',
    () async {
      // A second tracked file with an uncommitted edit that is NOT part of the
      // stash — it must survive the undo (and its restore exercises the
      // snapshot `apply --index` path).
      await write('keep.txt', 'base\n');
      await raw(['add', 'keep.txt']);
      await raw(['commit', '-q', '-m', 'add keep']);

      final entry = (await pushStash('alpha', message: 'alpha')).single;
      await write('keep.txt', 'mine\n'); // unrelated, added AFTER the stash
      await git.stashPop(repo, entry.index, expectedOid: entry.oid);
      expect(await File('$repo/f.txt').readAsString(), 'alpha\n');
      expect(await File('$repo/keep.txt').readAsString(), 'mine\n');

      await git.undoExecute(records.single);
      expect(
        await File('$repo/f.txt').readAsString(),
        'base\n',
        reason: 'the popped change is reversed',
      );
      expect(
        await File('$repo/keep.txt').readAsString(),
        'mine\n',
        reason: 'the unrelated pre-pop change is preserved',
      );
      expect(await git.stashList(repo), hasLength(1));
    },
  );

  test(
    'pop undo refuses to discard edits made since the pop, unless forced',
    () async {
      final entry = (await pushStash('alpha', message: 'alpha')).single;
      await git.stashPop(repo, entry.index, expectedOid: entry.oid);
      // The user keeps working after the pop.
      await write('f.txt', 'edited-after-pop\n');

      await expectLater(
        git.undoExecute(records.single),
        throwsA(isA<UndoDirtyException>()),
        reason: 'reset --hard would eat the post-pop edit — guard it',
      );
      expect(
        await git.stashList(repo),
        isEmpty,
        reason: 'nothing restored yet',
      );
      expect(await File('$repo/f.txt').readAsString(), 'edited-after-pop\n');

      // Forcing discards the post-pop edit and completes the reversal.
      await git.undoExecute(records.single, force: true);
      expect(await File('$repo/f.txt').readAsString(), 'base\n');
      expect(await git.stashList(repo), hasLength(1));
    },
  );

  test('apply --index reinstates the staged state', () async {
    await write('f.txt', 'staged-change\n');
    await raw(['add', 'f.txt']); // staged when stashed
    await raw(['stash', 'push', '-q']);
    final entry = (await git.stashList(repo)).single;

    await git.stashApply(repo, entry.oid, restoreIndex: true);
    expect(
      await raw(['diff', '--cached', '--name-only']),
      'f.txt',
      reason: '--index brings the file back staged, not just in the worktree',
    );
  });

  test(
    'pop --index reinstates the staged state and still drops the entry',
    () async {
      await write('f.txt', 'staged-change\n');
      await raw(['add', 'f.txt']);
      await raw(['stash', 'push', '-q']);
      final entry = (await git.stashList(repo)).single;

      await git.stashPop(
        repo,
        entry.index,
        expectedOid: entry.oid,
        restoreIndex: true,
      );
      expect(await raw(['diff', '--cached', '--name-only']), 'f.txt');
      expect(
        await git.stashList(repo),
        isEmpty,
        reason: 'pop still consumes it',
      );
    },
  );

  test(
    'stash branch recovers onto a new branch, and undo reverses all of it',
    () async {
      final entry = (await pushStash('wip', message: 'wip')).single;

      await git.stashBranch(
        repo,
        'feature-x',
        index: entry.index,
        expectedOid: entry.oid,
      );
      expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'feature-x');
      expect(
        await File('$repo/f.txt').readAsString(),
        'wip\n',
        reason: 'the stash is applied on the new branch',
      );
      expect(
        await git.stashList(repo),
        isEmpty,
        reason: 'the stash is dropped once applied',
      );

      expect(records.single.kind, UndoOpKind.stashBranch);
      await git.undoExecute(records.single);
      expect(
        await raw(['symbolic-ref', '--short', 'HEAD']),
        'main',
        reason: 'back on the original branch',
      );
      expect(
        await File('$repo/f.txt').readAsString(),
        'base\n',
        reason: 'the applied changes are reversed',
      );
      expect(
        await git.stashList(repo),
        hasLength(1),
        reason: 'the stash is re-stored',
      );
      final branches = await raw(['branch', '--format=%(refname:short)']);
      expect(
        branches.split('\n'),
        isNot(contains('feature-x')),
        reason: 'the created branch is deleted',
      );
    },
  );

  test('stash branch aimed at a shifted list is refused', () async {
    final rendered = (await pushStash('alpha', message: 'alpha')).single;
    await pushStash('beta', message: 'beta'); // shifts the list under it

    await expectLater(
      git.stashBranch(
        repo,
        'nope',
        index: rendered.index,
        expectedOid: rendered.oid,
      ),
      throwsA(isA<StashStaleException>()),
    );
    expect(await git.stashList(repo), hasLength(2), reason: 'nothing consumed');
    final branches = await raw(['branch', '--format=%(refname:short)']);
    expect(
      branches.split('\n'),
      isNot(contains('nope')),
      reason: 'no branch created behind the guard',
    );
  });

  test(
    'stash branch undo refuses to discard edits made since, unless forced',
    () async {
      final entry = (await pushStash('wip', message: 'wip')).single;
      await git.stashBranch(
        repo,
        'feature-x',
        index: entry.index,
        expectedOid: entry.oid,
      );
      await write('f.txt', 'edited-after-branch\n'); // work on the new branch

      await expectLater(
        git.undoExecute(records.single),
        throwsA(isA<UndoDirtyException>()),
      );
      // Still on the created branch, nothing reversed.
      expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'feature-x');
      expect(await git.stashList(repo), isEmpty);

      await git.undoExecute(records.single, force: true);
      expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'main');
      expect(await git.stashList(repo), hasLength(1));
    },
  );

  test(
    'apply by OID lands on the right stash however the list has shifted',
    () async {
      final alpha = (await pushStash('alpha', message: 'alpha')).single;
      await pushStash('beta', message: 'beta');

      // alpha is now stash@{1}; its OID still names it.
      await git.stashApply(repo, alpha.oid);
      expect(await File('$repo/f.txt').readAsString(), 'alpha\n');
      expect(
        await git.stashList(repo),
        hasLength(2),
        reason: 'apply keeps the entry',
      );
    },
  );

  test('the preview includes untracked files stashed with -u', () async {
    await write('f.txt', 'tracked-edit\n');
    await write('brand-new.txt', 'untracked-content\n');
    await raw(['stash', 'push', '-q', '-u', '-m', 'with untracked']);
    final entry = (await git.stashList(repo)).single;

    final patch = await git.stashShow(repo, entry.oid);

    expect(patch, contains('tracked-edit'));
    expect(
      patch,
      contains('brand-new.txt'),
      reason: 'the plain form silently omitted the untracked third parent',
    );
    expect(patch, contains('untracked-content'));
  });

  test(
    'a path-scoped stash of a glob-named file takes exactly that file',
    () async {
      // The trap: a bare `a[1].txt` pathspec ALSO matches `a1.txt`, so an
      // unwrapped partial stash would rip a second file's edits into the stash.
      // :(literal) (see GitService._literal) turns matching off.
      await write('a[1].txt', 'bracket-base\n');
      await write('a1.txt', 'plain-base\n');
      await raw(['add', '-A']);
      await raw(['commit', '-q', '-m', 'two lookalike files']);
      await write('a[1].txt', 'bracket-edit\n');
      await write('a1.txt', 'plain-edit\n');

      await git.stashPush(repo, includeUntracked: true, paths: ['a[1].txt']);

      // Only the named file was stashed; the lookalike's edit stays in the tree.
      expect(await File('$repo/a[1].txt').readAsString(), 'bracket-base\n');
      expect(
        await File('$repo/a1.txt').readAsString(),
        'plain-edit\n',
        reason: 'a bare pathspec would have glob-stashed this file too',
      );
      expect(await git.stashList(repo), hasLength(1));
    },
  );
}
