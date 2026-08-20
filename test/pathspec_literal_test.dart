// Exact paths must mean exactly one file — against real git, because the bug
// this pins is real git behavior: a bare pathspec is a GLOB-ACTIVE pattern.
// `pages/[id].tsx` (a routing filename on half the JS frameworks) also
// matches `pages/i.tsx`, so before `:(literal)` hardening a discard aimed at
// the one file silently destroyed another file's edits, staging staged
// bystanders, and `git clean` deleted untracked files the user never named.
// A file with a leading `:` couldn't be named at all (parsed as pathspec
// magic). Verified against git 2.55.
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

  void write(String path, String content) {
    final file = File('$repo/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String path) => File('$repo/$path').readAsStringSync();

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pathspec_lit_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    git = GitService(LocalCommandExecutor());
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);

    // The glob trap: `[id]` is a character class matching `i` or `d`.
    write('pages/[id].tsx', 'route\n');
    write('pages/i.tsx', 'plain-i\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'init']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test(
    'discard touches EXACTLY the named file, not its glob matches',
    () async {
      write('pages/[id].tsx', 'edited-route\n');
      write('pages/i.tsx', 'edited-i\n');

      await git.discard(repo, 'pages/[id].tsx');

      expect(read('pages/[id].tsx'), 'route\n', reason: 'named file discarded');
      expect(
        read('pages/i.tsx'),
        'edited-i\n',
        reason: "the sibling the glob would match must keep the user's edit",
      );
    },
  );

  test('stage touches exactly the named file', () async {
    write('pages/[id].tsx', 'edited-route\n');
    write('pages/i.tsx', 'edited-i\n');

    await git.stage(repo, 'pages/[id].tsx');

    final staged = await raw(['diff', '--cached', '--name-only']);
    expect(staged, 'pages/[id].tsx');
  });

  test('unstage and discardStaged touch exactly the named file', () async {
    write('pages/[id].tsx', 'edited-route\n');
    write('pages/i.tsx', 'edited-i\n');
    await raw(['add', '-A']);

    await git.unstage(repo, 'pages/[id].tsx');
    expect(await raw(['diff', '--cached', '--name-only']), 'pages/i.tsx');

    await git.discardStaged(repo, 'pages/i.tsx');
    expect(await raw(['diff', '--cached', '--name-only']), isEmpty);
    expect(read('pages/i.tsx'), 'plain-i\n');
    expect(read('pages/[id].tsx'), 'edited-route\n', reason: 'untouched');
  });

  test('removing an untracked file deletes exactly the named file', () async {
    write('notes[1].txt', 'doomed\n');
    write('notes1.txt', 'bystander\n');

    await git.removeUntrackedFile(repo, 'notes[1].txt');

    expect(File('$repo/notes[1].txt').existsSync(), isFalse);
    expect(
      File('$repo/notes1.txt').existsSync(),
      isTrue,
      reason: 'clean must not delete the glob-matched bystander',
    );
  });

  test(
    'a file whose name starts with ":" can be staged and discarded',
    () async {
      write(':colon.txt', 'v1\n');
      await git.stage(repo, ':colon.txt');
      expect(await raw(['diff', '--cached', '--name-only']), ':colon.txt');

      await raw(['commit', '-q', '-m', 'colon']);
      write(':colon.txt', 'v2\n');
      await git.discard(repo, ':colon.txt');
      expect(read(':colon.txt'), 'v1\n');
    },
  );

  test('a "*" in the name stays literal for stage and discard', () async {
    write('a*b.txt', 'star\n');
    write('axxb.txt', 'xx\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'star']);

    write('a*b.txt', 'star-edit\n');
    write('axxb.txt', 'xx-edit\n');
    await git.discard(repo, 'a*b.txt');

    expect(read('a*b.txt'), 'star\n');
    expect(read('axxb.txt'), 'xx-edit\n');
  });

  test(
    'diff, blame and file-history log are scoped to the named file',
    () async {
      write('pages/[id].tsx', 'edited-route\n');
      write('pages/i.tsx', 'edited-i\n');

      final diff = await git.diffFile(
        repo,
        path: 'pages/[id].tsx',
        staged: false,
      );
      expect(diff, contains('[id].tsx'));
      expect(
        diff,
        isNot(contains('pages/i.tsx')),
        reason: 'the diff pane must not mix in a glob-matched sibling',
      );

      final history = await git.log(repo, path: 'pages/[id].tsx', follow: true);
      expect(history, hasLength(1));

      final blame = await git.blame(repo, 'pages/[id].tsx');
      expect(blame, isNotEmpty);
    },
  );

  test('conflict resolution resolves exactly the named file', () async {
    // Build a conflict on [id].tsx while i.tsx also differs between branches.
    await raw(['checkout', '-q', '-b', 'side']);
    write('pages/[id].tsx', 'side-route\n');
    write('pages/i.tsx', 'side-i\n');
    await raw(['commit', '-q', '-am', 'side']);
    await raw(['checkout', '-q', 'main']);
    write('pages/[id].tsx', 'main-route\n');
    write('pages/i.tsx', 'main-i\n');
    await raw(['commit', '-q', '-am', 'main']);
    final merge = await Process.run('git', [
      'merge',
      'side',
    ], workingDirectory: repo);
    expect(merge.exitCode, isNot(0), reason: 'setup expects a conflict');

    await git.resolveConflict(repo, 'pages/[id].tsx', useOurs: true);

    expect(read('pages/[id].tsx'), 'main-route\n');
    final unmerged = await raw(['diff', '--name-only', '--diff-filter=U']);
    expect(unmerged, 'pages/i.tsx', reason: 'the sibling stays unmerged');
  });

  test('undo of a discard restores exactly the named file', () async {
    write('pages/[id].tsx', 'edited-route\n');
    write('pages/i.tsx', 'edited-i\n');

    UndoRecord? recorded;
    final recordingGit = GitService(
      LocalCommandExecutor(),
      onUndoRecord: (r) => recorded = r,
    );
    await recordingGit.discard(repo, 'pages/[id].tsx');
    expect(recorded, isNotNull, reason: 'discard records an undo entry');

    // Undo brings the discarded edit back — and only it.
    await git.undoExecute(recorded!);
    expect(read('pages/[id].tsx'), 'edited-route\n');
    expect(read('pages/i.tsx'), 'edited-i\n');
  });
}
