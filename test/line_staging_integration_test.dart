@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

void main() {
  late Directory scratch;
  late String repo;
  late List<UndoRecord> undoRecords;
  late GitService git;

  Future<String> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'git ${args.join(' ')} failed: ${result.stderr}',
    );
    return (result.stdout as String).trimRight();
  }

  Future<void> write(String path, String content) async {
    final file = File('$repo/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  SelectionPatchBuilt selectWhere(
    String patch,
    bool Function(String line) select,
  ) {
    final file = parseUnifiedDiff(patch)!;
    final rows = <int>{};
    for (var index = 0; index < file.hunks.single.lines.length; index++) {
      final line = file.hunks.single.lines[index];
      final kind = diffLineKind(line);
      if ((kind == DiffLineKind.add || kind == DiffLineKind.remove) &&
          select(line)) {
        rows.add(index);
      }
    }
    return buildSelectionPatch(file, {0: rows}) as SelectionPatchBuilt;
  }

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('line_staging_test_');
    repo = scratch.resolveSymbolicLinksSync();
    undoRecords = [];
    git = GitService(LocalCommandExecutor(), onUndoRecord: undoRecords.add);
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Test']);
    await raw(['config', 'user.email', 'test@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await write('mixed.txt', 'alpha\nold one\nmiddle\nold two\nomega\n');
    await raw(['add', 'mixed.txt']);
    await raw(['commit', '-q', '-m', 'initial']);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on PathNotFoundException {
      // An executor cleanup may finish first.
    }
  });

  test(
    'mixed add/remove stages and reverse-unstages only the selection',
    () async {
      await write('mixed.txt', 'alpha\nnew one\nmiddle\nnew two\nomega\n');
      final diff = await git.diffFile(repo, path: 'mixed.txt', staged: false);
      final selected = selectWhere(
        diff,
        (line) => line == '-old one' || line == '+new one',
      );

      await git.applySelectionPatch(repo, selected.patch, reverse: false);
      final cached = await git.diffFile(repo, path: 'mixed.txt', staged: true);
      expect(cached, contains('-old one'));
      expect(cached, contains('+new one'));
      expect(cached, isNot(contains('new two')));
      expect(
        await git.diffFile(repo, path: 'mixed.txt', staged: false),
        contains('new two'),
      );

      final reverse = selectWhere(
        cached,
        (line) => line == '-old one' || line == '+new one',
      );
      await git.applySelectionPatch(repo, reverse.patch, reverse: true);
      expect(await raw(['diff', '--cached', '--name-only']), isEmpty);
    },
  );

  test('new and deleted files support partial index construction', () async {
    await write('new.txt', 'one\ntwo\n');
    final newDiff = await git.diffUntracked(repo, 'new.txt');
    final selectedNew = selectWhere(newDiff, (line) => line == '+one');
    await git.applySelectionPatch(repo, selectedNew.patch, reverse: false);
    expect(await raw(['show', ':new.txt']), 'one');

    await raw(['reset', '-q']);
    await write('delete.txt', 'one\ntwo\n');
    await raw(['add', 'delete.txt']);
    await raw(['commit', '-q', '-m', 'add delete fixture']);
    await File('$repo/delete.txt').delete();
    final deleteDiff = await git.diffFile(
      repo,
      path: 'delete.txt',
      staged: false,
    );
    final selectedDelete = selectWhere(
      deleteDiff,
      (line) => line == '-one' || line == '-two',
    );
    await git.applySelectionPatch(repo, selectedDelete.patch, reverse: false);
    expect(await raw(['diff', '--cached', '--name-status']), 'D\tdelete.txt');
  });

  test('Unicode, no newline, and literal-looking paths apply safely', () async {
    const path = '-[glob]☕.txt';
    await write(path, 'café');
    await raw(['add', '--', path]);
    await raw(['commit', '-q', '-m', 'unicode fixture']);
    await write(path, 'café ☕');
    final diff = await git.diffFile(repo, path: path, staged: false);
    final selected = selectWhere(
      diff,
      (line) => line == '-café' || line == '+café ☕',
    );

    await git.applySelectionPatch(repo, selected.patch, reverse: false);
    expect(await raw(['show', ':$path']), 'café ☕');
    expect(await raw(['diff', '--cached', '--name-only']), isNotEmpty);
  });

  test(
    'rename headers remain authoritative while staging selected edits',
    () async {
      await write('old-name.txt', 'one\ntwo\nthree\n');
      await raw(['add', 'old-name.txt']);
      await raw(['commit', '-q', '-m', 'rename fixture']);
      await File('$repo/old-name.txt').rename('$repo/new-name.txt');
      await write('new-name.txt', 'one\nTWO\nthree\n');
      await raw(['add', '-N', '--', 'new-name.txt']);
      final diff = await raw(['diff', '--find-renames=40%']);
      final file = parseCommitPatch(
        diff,
      ).files.singleWhere((candidate) => candidate.newPath == 'new-name.txt');
      final selectedRows = <int>{};
      for (var index = 0; index < file.hunks.single.lines.length; index++) {
        final line = file.hunks.single.lines[index];
        if (line == '-two' || line == '+TWO') selectedRows.add(index);
      }
      final selected = buildSelectionPatch(file, {0: selectedRows});

      await git.applySelectionPatch(
        repo,
        (selected as SelectionPatchBuilt).patch,
        reverse: false,
      );
      expect(await raw(['show', ':new-name.txt']), contains('TWO'));
    },
  );

  test('selected discard is snapshotted and undo restores the file', () async {
    await write('mixed.txt', 'alpha\nold one\nmiddle\nold two\nomega\ntail\n');
    final diff = await git.diffFile(repo, path: 'mixed.txt', staged: false);
    final selected = selectWhere(diff, (line) => line == '+tail');

    await git.discardSelectionPatch(repo, selected.patch, path: 'mixed.txt');
    expect(
      await File('$repo/mixed.txt').readAsString(),
      isNot(contains('tail')),
    );
    expect(undoRecords.single.snapshotOid, isNotEmpty);

    await git.undoExecute(undoRecords.single);
    expect(await File('$repo/mixed.txt').readAsString(), contains('tail'));
  });

  test(
    'external edit race fails without partially changing the index',
    () async {
      await write('mixed.txt', 'alpha\nnew one\nmiddle\nold two\nomega\n');
      final diff = await git.diffFile(repo, path: 'mixed.txt', staged: false);
      final selected = selectWhere(
        diff,
        (line) => line == '-old one' || line == '+new one',
      );
      await write('mixed.txt', 'externally replaced\n');
      await raw(['add', 'mixed.txt']);
      final before = await raw(['rev-parse', ':mixed.txt']);

      await expectLater(
        () => git.applySelectionPatch(repo, selected.patch, reverse: false),
        throwsA(isA<GitException>()),
      );
      expect(await raw(['rev-parse', ':mixed.txt']), before);
      expect(
        await File('$repo/mixed.txt').readAsString(),
        'externally replaced\n',
      );
    },
  );
}
