// File history must survive renames — the point of `--follow`. The claim that
// broke: a per-commit diff scoped to the file's CURRENT name is silently empty
// for commits from before a rename (`git show <pre-rename> -- <new-name>`
// prints the header and no patch, exit 0), so the walk has to carry the name
// the file bore at each commit. That is a claim about git's output shapes
// (`--name-status` records, rename entries, path quoting), so it is checked
// against a real repository. Also pins the interactive-rebase range walk:
// `git log <parent>..HEAD` contains the selected commit exactly when HEAD
// descends from it, at any depth — the ancestry-and-range query the rebase
// sheet now builds its todo from.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory repo;
  late GitService git;

  Future<void> run(List<String> args) async {
    final r = await Process.run(
      args.first,
      args.skip(1).toList(),
      workingDirectory: repo.path,
    );
    if (r.exitCode != 0) {
      throw StateError('fixture setup failed: ${args.join(' ')}\n${r.stderr}');
    }
  }

  Future<void> commitAll(String subject) async {
    await run(['git', 'add', '--all']);
    await run([
      'git',
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.com',
      'commit',
      '-m',
      subject,
    ]);
  }

  setUpAll(() async {
    repo = Directory.systemTemp.createTempSync('file_history_test_');
    git = GitService(LocalCommandExecutor());
    await run(['git', 'init', '-b', 'main']);
    await File('${repo.path}/old_name.txt').writeAsString('a\n');
    await commitAll('add old_name');
    await File('${repo.path}/old_name.txt').writeAsString('a\nb\n');
    await commitAll('edit old_name');
    await run(['git', 'mv', 'old_name.txt', 'new_name.txt']);
    await commitAll('rename to new_name');
    await File('${repo.path}/new_name.txt').writeAsString('a\nb\nc\n');
    await commitAll('edit new_name');
  });

  tearDownAll(() => repo.deleteSync(recursive: true));

  test('the walk crosses the rename and carries the per-commit path', () async {
    final entries = await git.fileHistory(repo.path, 'new_name.txt');
    expect(
      [for (final e in entries) e.commit.subject],
      ['edit new_name', 'rename to new_name', 'edit old_name', 'add old_name'],
      reason: '--follow walks through the rename',
    );
    expect(
      [for (final e in entries) e.pathAtCommit],
      [
        'new_name.txt',
        // At the rename commit the file IS new_name.txt (the R record's new
        // side) — scoping there shows the rename's content arriving.
        'new_name.txt',
        'old_name.txt',
        'old_name.txt',
      ],
      reason: 'each commit is asked about under the name it actually used',
    );
  });

  test('scoping a pre-rename commit by its own name yields a real diff — '
      'and by the current name, nothing at all', () async {
    final entries = await git.fileHistory(repo.path, 'new_name.txt');
    final preRename = entries.singleWhere(
      (e) => e.commit.subject == 'edit old_name',
    );

    final scopedRight = await git.showCommit(
      repo.path,
      preRename.commit.hash,
      path: preRename.pathAtCommit,
    );
    expect(
      scopedRight,
      contains('+b'),
      reason: 'the edit is visible under the old name',
    );

    // The pre-fix behavior, pinned as the failure it is: the current name
    // produces the commit header with NO patch — the silently blank pane.
    final scopedWrong = await git.showCommit(
      repo.path,
      preRename.commit.hash,
      path: 'new_name.txt',
    );
    expect(scopedWrong, isNot(contains('diff --git')));
  });

  test('a path needing quoting round-trips through --name-status', () async {
    await File('${repo.path}/with space "q".txt').writeAsString('x\n');
    await commitAll('add quoted-path file');
    final entries = await git.fileHistory(repo.path, 'with space "q".txt');
    expect(entries.single.commit.subject, 'add quoted-path file');
    expect(
      entries.single.pathAtCommit,
      'with space "q".txt',
      reason: 'git quotes the embedded double quote; the parser must undo it',
    );
  });

  test('the rebase range walk finds an ancestor at any depth and refuses a '
      'non-ancestor', () async {
    final head = await git.log(repo.path, maxCount: 100);
    final deepest = head.last; // the root's child chain bottom
    final target = head[head.length - 2]; // 'edit old_name'

    final range = await git.log(
      repo.path,
      revision: '${target.parents.first}..HEAD',
      maxCount: 10000,
    );
    expect(
      range.any((c) => c.hash == target.hash),
      isTrue,
      reason:
          'parent..HEAD contains the commit exactly when HEAD descends '
          'from it — the membership test doubles as the ancestry test',
    );
    expect(
      range.length,
      head.length - 1,
      reason: 'exactly the commits the rebase would rewrite',
    );

    // A side branch's commit is not in parent..HEAD.
    await run(['git', 'checkout', '-b', 'side', deepest.hash]);
    await File('${repo.path}/side.txt').writeAsString('s\n');
    await commitAll('side commit');
    final sideHash = (await git.log(repo.path, maxCount: 1)).single.hash;
    await run(['git', 'checkout', 'main']);

    final sideRange = await git.log(
      repo.path,
      revision: '${deepest.hash}..HEAD',
      maxCount: 10000,
    );
    expect(
      sideRange.any((c) => c.hash == sideHash),
      isFalse,
      reason: 'a commit HEAD does not descend from never appears in the range',
    );
  });
}
