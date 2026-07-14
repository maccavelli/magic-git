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

  test('a drop aimed at a shifted list is refused — nothing dropped',
      () async {
    final rendered = (await pushStash('alpha', message: 'alpha')).single;
    // The list shifts AFTER the UI rendered it: a new stash lands on top.
    await pushStash('beta', message: 'beta');

    await expectLater(
      git.stashDrop(repo, rendered.index, expectedOid: rendered.oid),
      throwsA(isA<StashStaleException>()),
    );
    expect(await git.stashList(repo), hasLength(2),
        reason: 'the guard must leave every stash in place');
  });

  test('a drop aimed at a current list drops exactly that stash, undoably',
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
  });

  test('pop journals the popped stash so it is recoverable', () async {
    final entry = (await pushStash('alpha', message: 'alpha')).single;

    await git.stashPop(repo, entry.index, expectedOid: entry.oid);
    expect(await git.stashList(repo), isEmpty);
    expect(await File('$repo/f.txt').readAsString(), 'alpha\n',
        reason: 'popped content applied');

    expect(records.single.kind, UndoOpKind.stashDrop);
    await git.undoExecute(records.single);
    expect(await git.stashList(repo), hasLength(1),
        reason: 'the stash entry itself is back');
  });

  test('apply by OID lands on the right stash however the list has shifted',
      () async {
    final alpha = (await pushStash('alpha', message: 'alpha')).single;
    await pushStash('beta', message: 'beta');

    // alpha is now stash@{1}; its OID still names it.
    await git.stashApply(repo, alpha.oid);
    expect(await File('$repo/f.txt').readAsString(), 'alpha\n');
    expect(await git.stashList(repo), hasLength(2),
        reason: 'apply keeps the entry');
  });

  test('the preview includes untracked files stashed with -u', () async {
    await write('f.txt', 'tracked-edit\n');
    await write('brand-new.txt', 'untracked-content\n');
    await raw(['stash', 'push', '-q', '-u', '-m', 'with untracked']);
    final entry = (await git.stashList(repo)).single;

    final patch = await git.stashShow(repo, entry.oid);

    expect(patch, contains('tracked-edit'));
    expect(patch, contains('brand-new.txt'),
        reason: 'the plain form silently omitted the untracked third parent');
    expect(patch, contains('untracked-content'));
  });
}
