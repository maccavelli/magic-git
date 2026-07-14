// End-to-end undo against real git in scratch repos (LocalCommandExecutor —
// same honest-test rationale as local_command_executor_test.dart): the capture
// scripts must parse real shell output, and undoExecute's validate+execute
// scripts must restore real repo state, refuse stale records, and survive
// detached HEADs.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

void main() {
  late Directory tempDir;
  late String repo;
  late LocalCommandExecutor executor;
  late List<UndoRecord> records;
  late GitService git;

  /// Runs a raw git command for setup/verification — bypasses GitService so
  /// it can never pollute [records].
  Future<String> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(result.exitCode, 0,
        reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  Future<void> write(String name, String content) =>
      File('$repo/$name').writeAsString(content);

  /// `git status --porcelain` with only the trailing newline stripped — the
  /// leading space of ` M` (worktree-modified) is significant and [raw]'s
  /// trim would eat it.
  Future<String> porcelain([List<String> paths = const []]) async {
    final result = await Process.run(
      'git',
      ['status', '--porcelain', if (paths.isNotEmpty) '--', ...paths],
      workingDirectory: repo,
    );
    expect(result.exitCode, 0);
    var out = result.stdout as String;
    if (out.endsWith('\n')) out = out.substring(0, out.length - 1);
    return out;
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('undo_scripts_test_');
    repo = tempDir.path;
    executor = LocalCommandExecutor();
    records = [];
    git = GitService(executor, onUndoRecord: records.add);

    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Test']);
    await raw(['config', 'user.email', 'test@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await write('a.txt', 'one\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'first']);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('the first commit on an unborn branch records nothing', () async {
    final fresh = Directory.systemTemp.createTempSync('undo_unborn_');
    addTearDown(() => fresh.deleteSync(recursive: true));
    await Process.run('git', ['init', '-q', '-b', 'main'],
        workingDirectory: fresh.path);
    await Process.run('git', ['config', 'user.name', 'T'],
        workingDirectory: fresh.path);
    await Process.run('git', ['config', 'user.email', 't@e.c'],
        workingDirectory: fresh.path);
    File('${fresh.path}/x').writeAsStringSync('x');
    await Process.run('git', ['add', 'x'], workingDirectory: fresh.path);
    await git.commit(fresh.path, message: 'first ever');
    expect(records, isEmpty);
  });

  test('undoing a commit restores HEAD with the content left staged',
      () async {
    await write('a.txt', 'two\n');
    await raw(['add', 'a.txt']);
    await git.commit(repo, message: 'second');
    expect(await raw(['log', '--format=%s', '-1']), 'second');

    await git.undoExecute(records.single);

    expect(await raw(['log', '--format=%s', '-1']), 'first');
    // The committed change is back in the index, exactly pre-commit.
    expect(await raw(['diff', '--cached', '--name-only']), 'a.txt');
    expect(await raw(['status', '--porcelain']), 'M  a.txt');
  });

  test('undoing an amend restores the original commit', () async {
    final original = await raw(['rev-parse', 'HEAD']);
    await git.amendCommit(repo, message: 'first, reworded');
    expect(await raw(['log', '--format=%s', '-1']), 'first, reworded');

    await git.undoExecute(records.single);

    expect(await raw(['rev-parse', 'HEAD']), original);
    expect(await raw(['log', '--format=%s', '-1']), 'first');
  });

  test('a stale record is refused with UndoStaleException', () async {
    await write('a.txt', 'two\n');
    await raw(['add', 'a.txt']);
    await git.commit(repo, message: 'second');
    // Someone else moves the branch after the recorded operation.
    await write('a.txt', 'three\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'external']);

    await expectLater(
      () => git.undoExecute(records.single),
      throwsA(isA<UndoStaleException>()),
    );
    // And nothing moved.
    expect(await raw(['log', '--format=%s', '-1']), 'external');
  });

  test('undoing a mixed reset restores HEAD and the staged index', () async {
    await write('a.txt', 'two\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'second']);
    await write('b.txt', 'new\n');
    await raw(['add', 'b.txt']);

    await git.reset(repo, 'HEAD~1', mode: ResetMode.mixed);
    expect(await raw(['diff', '--cached', '--name-only']), '',
        reason: 'mixed reset unstages everything');

    await git.undoExecute(records.single);

    expect(await raw(['log', '--format=%s', '-1']), 'second');
    expect(await raw(['diff', '--cached', '--name-only']), 'b.txt',
        reason: 'the pre-reset staged state is restored from its tree');
  });

  test('undoing a checkout returns to the previous branch', () async {
    await raw(['branch', 'feature']);
    await git.checkout(repo, 'feature');
    expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'feature');

    await git.undoExecute(records.single);
    expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'main');
  });

  test('undoing a checkout made from a detached HEAD re-detaches', () async {
    final head = await raw(['rev-parse', 'HEAD']);
    await raw(['checkout', '-q', '--detach']);
    await git.checkout(repo, 'main');

    await git.undoExecute(records.single);
    final result =
        await Process.run('git', ['symbolic-ref', '-q', 'HEAD'],
            workingDirectory: repo);
    expect(result.exitCode, isNot(0), reason: 'HEAD is detached again');
    expect(await raw(['rev-parse', 'HEAD']), head);
  });

  test('undoing a branch delete recreates it at the same tip; a second undo '
      'of the same record is stale', () async {
    await raw(['branch', 'doomed']);
    final tip = await raw(['rev-parse', 'refs/heads/doomed']);
    await git.deleteBranch(repo, 'doomed', force: true);

    await git.undoExecute(records.single);
    expect(await raw(['rev-parse', 'refs/heads/doomed']), tip);

    // The branch exists again — replaying the record must refuse.
    await expectLater(
      () => git.undoExecute(records.single),
      throwsA(isA<UndoStaleException>()),
    );
  });

  test('undoing an annotated tag delete restores the tag object '
      'byte-identical', () async {
    await raw(['tag', '-a', '-m', 'release notes', 'v1.0']);
    final tagObject = await raw(['rev-parse', 'refs/tags/v1.0']);
    await git.deleteTag(repo, 'v1.0');

    await git.undoExecute(records.single);

    expect(await raw(['rev-parse', 'refs/tags/v1.0']), tagObject,
        reason: 'update-ref restores the identical annotated tag object');
    expect(await raw(['cat-file', '-t', 'v1.0']), 'tag');
  });

  test('undoing a discard restores the file content, unstaged, path-scoped',
      () async {
    await write('a.txt', 'modified\n');
    await write('other.txt', 'untouched\n');
    await raw(['add', 'other.txt']);

    await git.discard(repo, 'a.txt');
    expect(await File('$repo/a.txt').readAsString(), 'one\n');
    final record = records.single;
    expect(record.snapshotOid, isNotEmpty);
    // The snapshot is anchored on a hidden ref (never the stash list).
    expect(await raw(['rev-parse', record.snapshotOid]), record.snapshotOid);
    expect(await raw(['stash', 'list']), '');

    await git.undoExecute(record);
    expect(await File('$repo/a.txt').readAsString(), 'modified\n');
    expect(await porcelain(['a.txt']), ' M a.txt',
        reason: 'restored as an unstaged modification, exactly as before');
    expect(await porcelain(['other.txt']), 'A  other.txt',
        reason: 'unrelated staged work is untouched by the scoped restore');
  });

  test('discarding a hunk snapshots the file, and undo restores it', () async {
    // The hunk-scoped sibling of the discard above: before discardHunk
    // existed this went through a bare `git apply -R` with no snapshot, and
    // the confirm dialog honestly said "cannot be undone".
    await write('a.txt', 'CHANGED\n');
    final patch = await git.diffFile(repo, path: 'a.txt', staged: false);

    await git.discardHunk(repo, patch, path: 'a.txt');
    expect(await File('$repo/a.txt').readAsString(), 'one\n');

    final record = records.single;
    expect(record.snapshotOid, isNotEmpty);
    expect(record.description, contains('hunk'));

    await git.undoExecute(record);
    expect(await File('$repo/a.txt').readAsString(), 'CHANGED\n');
    expect(await porcelain(['a.txt']), ' M a.txt',
        reason: 'back as an unstaged modification, exactly as before');
  });

  test('a discard undo refuses to overwrite newer edits unless forced',
      () async {
    await write('a.txt', 'modified\n');
    await git.discard(repo, 'a.txt');
    // The user edits the file again after the discard.
    await write('a.txt', 'newer edit\n');

    await expectLater(
      () => git.undoExecute(records.single),
      throwsA(isA<UndoDirtyException>()),
    );
    expect(await File('$repo/a.txt').readAsString(), 'newer edit\n',
        reason: 'nothing overwritten without confirmation');

    await git.undoExecute(records.single, force: true);
    expect(await File('$repo/a.txt').readAsString(), 'modified\n');
  });

  test('undoing a staged discard of a never-committed file restores it '
      'staged', () async {
    await write('new.txt', 'brand new\n');
    await raw(['add', 'new.txt']);

    await git.discardStaged(repo, 'new.txt');
    expect(File('$repo/new.txt').existsSync(), isFalse,
        reason: 'no HEAD counterpart: discardStaged removes it entirely');

    await git.undoExecute(records.single);
    expect(await File('$repo/new.txt').readAsString(), 'brand new\n');
    expect(await raw(['status', '--porcelain', '--', 'new.txt']), 'A  new.txt',
        reason: 'restored to the index from the snapshot^2 tree');
  });

  test('undoing an untracked deletion restores the files, still untracked',
      () async {
    await write('loose notes.txt', 'important\n');
    await write('scratch.txt', 'also important\n');

    await git.removeUntrackedFilesMany(repo, ['loose notes.txt', 'scratch.txt']);
    expect(File('$repo/loose notes.txt').existsSync(), isFalse);
    expect(File('$repo/scratch.txt').existsSync(), isFalse);

    await git.undoExecute(records.single);
    expect(await File('$repo/loose notes.txt').readAsString(), 'important\n');
    expect(await File('$repo/scratch.txt').readAsString(), 'also important\n');
    expect(
      await raw(['status', '--porcelain']),
      '?? "loose notes.txt"\n?? scratch.txt',
      reason: 'they come back untracked, exactly as they were',
    );
  });

  test('undoing a hard reset restores HEAD and the uncommitted changes',
      () async {
    await write('a.txt', 'two\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'second']);
    await write('a.txt', 'uncommitted work\n');

    await git.reset(repo, 'HEAD~1', mode: ResetMode.hard);
    expect(await File('$repo/a.txt').readAsString(), 'one\n');
    final record = records.single;
    expect(record.snapshotOid, isNotEmpty);

    await git.undoExecute(record);
    expect(await raw(['log', '--format=%s', '-1']), 'second');
    expect(await File('$repo/a.txt').readAsString(), 'uncommitted work\n');
    expect(await porcelain(), ' M a.txt');
  });

  test('a clean-tree hard reset records with no snapshot and undoes exactly',
      () async {
    await write('a.txt', 'two\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'second']);

    await git.reset(repo, 'HEAD~1', mode: ResetMode.hard);
    final record = records.single;
    expect(record.snapshotOid, '',
        reason: 'nothing uncommitted: stash create had nothing to capture');

    await git.undoExecute(record);
    expect(await raw(['log', '--format=%s', '-1']), 'second');
    expect(await raw(['status', '--porcelain']), '');
  });

  test('expired snapshot refs are pruned when a new snapshot is taken',
      () async {
    await raw([
      'update-ref',
      '${GitService.snapshotRefPrefix}1000000000-1', // epoch year 2001
      'HEAD',
    ]);
    await write('a.txt', 'modified\n');
    await git.discard(repo, 'a.txt');

    final refs = await raw(['for-each-ref', '--format=%(refname)',
        'refs/magic-git/snapshots']);
    expect(refs, isNot(contains('1000000000-1')), reason: 'ancient ref pruned');
    expect(refs, contains(GitService.snapshotRefPrefix),
        reason: 'the fresh snapshot itself is anchored');
  });

  test('undoing a clean merge restores the pre-merge HEAD', () async {
    await raw(['checkout', '-q', '-b', 'feature']);
    await write('feature.txt', 'feature work\n');
    await raw(['add', 'feature.txt']);
    await raw(['commit', '-q', '-m', 'feature commit']);
    await raw(['checkout', '-q', 'main']);
    final preMerge = await raw(['rev-parse', 'HEAD']);

    await git.merge(repo, 'feature', mode: MergeMode.noFf);
    expect(await raw(['rev-parse', 'HEAD']), isNot(preMerge));

    await git.undoExecute(records.single);
    expect(await raw(['rev-parse', 'HEAD']), preMerge);
    expect(File('$repo/feature.txt').existsSync(), isFalse);
    expect(await porcelain(), '');
  });

  test('undoing a merge over a dirty tree needs force, then restores the '
      'dirty state too', () async {
    await raw(['checkout', '-q', '-b', 'feature']);
    await write('feature.txt', 'feature work\n');
    await raw(['add', 'feature.txt']);
    await raw(['commit', '-q', '-m', 'feature commit']);
    await raw(['checkout', '-q', 'main']);
    // Unrelated uncommitted work the merge allows through.
    await write('a.txt', 'uncommitted\n');
    final preMerge = await raw(['rev-parse', 'HEAD']);

    await git.merge(repo, 'feature', mode: MergeMode.noFf);
    final record = records.single;
    expect(record.snapshotOid, isNotEmpty,
        reason: 'the dirty survivor was snapshotted');

    // The tree is non-empty (the surviving dirt), so the blanket hard-reset
    // guard fires — the user confirms, and the snapshot brings the dirt back.
    await expectLater(
      () => git.undoExecute(record),
      throwsA(isA<UndoDirtyException>()),
    );
    await git.undoExecute(record, force: true);
    expect(await raw(['rev-parse', 'HEAD']), preMerge);
    expect(await File('$repo/a.txt').readAsString(), 'uncommitted\n');
    expect(await porcelain(), ' M a.txt');
  });

  test('a conflicted merge throws and records nothing', () async {
    await raw(['checkout', '-q', '-b', 'feature']);
    await write('a.txt', 'feature version\n');
    await raw(['commit', '-qam', 'feature change']);
    await raw(['checkout', '-q', 'main']);
    await write('a.txt', 'main version\n');
    await raw(['commit', '-qam', 'main change']);

    await expectLater(
      () => git.merge(repo, 'feature'),
      throwsA(isA<GitException>()),
    );
    expect(records, isEmpty, reason: 'the abort flow owns conflicted merges');
    await raw(['merge', '--abort']);
  });

  test('undoing a clean cherry-pick restores the pre-pick HEAD', () async {
    await raw(['checkout', '-q', '-b', 'feature']);
    await write('picked.txt', 'cherry\n');
    await raw(['add', 'picked.txt']);
    await raw(['commit', '-q', '-m', 'to pick']);
    final pickHash = await raw(['rev-parse', 'HEAD']);
    await raw(['checkout', '-q', 'main']);
    final pre = await raw(['rev-parse', 'HEAD']);

    await git.cherryPick(repo, pickHash);
    expect(await raw(['log', '--format=%s', '-1']), 'to pick');

    await git.undoExecute(records.single);
    expect(await raw(['rev-parse', 'HEAD']), pre);
    expect(File('$repo/picked.txt').existsSync(), isFalse);
  });

  test('undoing a completed interactive rebase restores the old branch tip',
      () async {
    await write('a.txt', 'two\n');
    await raw(['commit', '-qam', 'second']);
    final second = await raw(['rev-parse', 'HEAD']);
    await write('a.txt', 'three\n');
    await raw(['commit', '-qam', 'third']);
    final third = await raw(['rev-parse', 'HEAD']);
    final first = await raw(['rev-parse', 'HEAD~2']);

    // Drop "third" by omitting it from the todo.
    await git.rebaseInteractive(repo, first, [
      RebaseStep(RebaseAction.pick, second),
      const RebaseStep(RebaseAction.drop, 'ignored'),
    ]);
    expect(await raw(['rev-parse', 'HEAD']), second);

    await git.undoExecute(records.single);
    expect(await raw(['rev-parse', 'HEAD']), third,
        reason: 'the dropped commit is back on the branch');
    expect(await raw(['log', '--format=%s', '-1']), 'third');
  });

  test('undoing a stash clear re-stores every stash in order', () async {
    await write('a.txt', 'wip one\n');
    await raw(['stash', 'push', '-q', '-m', 'first wip']);
    await write('a.txt', 'wip two\n');
    await raw(['stash', 'push', '-q', '-m', 'second wip']);

    await git.stashClear(repo);
    expect(await raw(['stash', 'list']), '');

    await git.undoExecute(records.single);
    final list = await raw(['stash', 'list', '--format=%gs']);
    expect(list.split('\n'), [
      contains('second wip'),
      contains('first wip'),
    ], reason: 'newest back at stash@{0}, original order preserved');
  });

  test('undoing a checked-out branch creation returns and deletes it',
      () async {
    await git.createBranch(repo, 'experiment');
    expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'experiment');
    final record = records.single;

    await git.undoExecute(record);
    expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'main');
    final probe = await Process.run(
      'git',
      ['rev-parse', '-q', '--verify', 'refs/heads/experiment'],
      workingDirectory: repo,
    );
    expect(probe.exitCode, isNot(0), reason: 'branch deleted');

    // Replaying the record must refuse — the branch no longer matches.
    await expectLater(
      () => git.undoExecute(record),
      throwsA(isA<UndoStaleException>()),
    );
  });

  test('undoing branchFrom (no checkout) deletes without switching; a moved '
      'branch is stale', () async {
    final tip = await raw(['rev-parse', 'HEAD']);
    await git.branchFrom(repo, 'pin', 'HEAD', checkout: false);
    expect(await raw(['rev-parse', 'refs/heads/pin']), tip);
    final record = records.single;
    expect(record.deletedOid, tip);

    // Someone moves the branch after creation — undo must refuse to delete.
    await write('a.txt', 'two\n');
    await raw(['commit', '-qam', 'second']);
    await raw(['branch', '-f', 'pin', 'HEAD']);
    await expectLater(
      () => git.undoExecute(record),
      throwsA(isA<UndoStaleException>()),
    );

    // Restore it to the recorded tip: undo now proceeds, without switching.
    await raw(['branch', '-f', 'pin', tip]);
    await git.undoExecute(record);
    expect(await raw(['symbolic-ref', '--short', 'HEAD']), 'main');
    final probe = await Process.run(
      'git',
      ['rev-parse', '-q', '--verify', 'refs/heads/pin'],
      workingDirectory: repo,
    );
    expect(probe.exitCode, isNot(0));
  });

  test('reflog lists real entries with parsed actions, newest first',
      () async {
    await write('a.txt', 'two\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'second']);
    await raw(['checkout', '-q', '-b', 'feature']);

    final entries = await git.reflog(repo);
    expect(entries.length, greaterThanOrEqualTo(3));
    expect(entries.first.action, 'checkout');
    expect(entries.first.detail, 'moving from main to feature');
    expect(entries.first.hash, await raw(['rev-parse', 'HEAD']));
    expect(entries[1].action, 'commit');
    expect(entries.first.selector, startsWith('HEAD@{'));
  });

  test('snapshotRefs lists anchors; restore and delete round-trip', () async {
    // A deletion creates a flavor-B snapshot…
    await write('notes.txt', 'precious\n');
    await git.deleteFile(repo, 'notes.txt');
    expect(File('$repo/notes.txt').existsSync(), isFalse);

    final snapshots = await git.snapshotRefs(repo);
    expect(snapshots, hasLength(1));
    final snapshot = snapshots.single;
    expect(snapshot.isUntrackedSnapshot, isTrue);
    expect(snapshot.refName, startsWith(GitService.snapshotRefPrefix));
    expect(snapshot.oid, records.single.snapshotOid);

    // …restorable from the Recovery sheet independently of the ⌘Z journal…
    await git.restoreSnapshot(repo, snapshot);
    expect(await File('$repo/notes.txt').readAsString(), 'precious\n');
    expect(await porcelain(['notes.txt']), '?? notes.txt');

    // …and deletable.
    await git.deleteSnapshot(repo, snapshot);
    expect(await git.snapshotRefs(repo), isEmpty);
  });

  test('restoring a flavor-A snapshot applies like a stash', () async {
    await write('a.txt', 'modified\n');
    await git.discard(repo, 'a.txt');
    expect(await File('$repo/a.txt').readAsString(), 'one\n');

    final snapshot = (await git.snapshotRefs(repo)).single;
    expect(snapshot.isUntrackedSnapshot, isFalse);

    await git.restoreSnapshot(repo, snapshot);
    expect(await File('$repo/a.txt').readAsString(), 'modified\n');
  });

  test('undoing a stash drop re-stores the stash with its subject', () async {
    await write('a.txt', 'wip\n');
    await raw(['stash', 'push', '-q', '-m', 'my wip']);
    final subject = await raw(['log', '-1', '--format=%s', 'stash@{0}']);
    final oid = await raw(['rev-parse', 'stash@{0}']);

    await git.stashDrop(repo, 0, expectedOid: oid);
    expect(await raw(['stash', 'list']), '');

    await git.undoExecute(records.single);
    final list = await raw(['stash', 'list', '--format=%gs']);
    expect(list, subject);
    // The restored stash applies cleanly.
    await raw(['stash', 'pop', '-q']);
    expect(await File('$repo/a.txt').readAsString(), 'wip\n');
  });
}
