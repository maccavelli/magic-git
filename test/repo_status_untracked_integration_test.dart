// Untracked-file handling against real git (July 2026 repository-tab pass):
//
//  * status runs `-uall`, so a wholly-untracked directory is reported as its
//    individual files — never as one collapsed `dir/` record. Every per-file
//    affordance (diff pane, delete, prefetch, the structure signature) assumes
//    real file paths; the collapsed row rendered a silently blank diff pane.
//  * diffUntracked surfaces git's exit-1-with-error shape (empty stdout,
//    stderr set — e.g. the path vanished between status and this read) as a
//    failure instead of presenting it as an empty, successful diff.
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

  Future<void> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('untracked_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    git = GitService(LocalCommandExecutor());
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['commit', '-q', '--allow-empty', '-m', 'init']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test(
    'status lists files inside an untracked directory individually (-uall)',
    () async {
      Directory('$repo/newdir/sub').createSync(recursive: true);
      File('$repo/newdir/a.txt').writeAsStringSync('a\n');
      File('$repo/newdir/sub/b.txt').writeAsStringSync('b\n');

      final status = await git.status(repo);
      final untracked = status.untracked.map((f) => f.path).toSet();
      expect(untracked, {'newdir/a.txt', 'newdir/sub/b.txt'});
      // The collapsed form is exactly what -uall exists to prevent.
      expect(untracked.any((p) => p.endsWith('/')), isFalse);
    },
  );

  test(
    'diffUntracked renders an untracked file as an additions diff',
    () async {
      File('$repo/new.txt').writeAsStringSync('hello\n');
      final diff = await git.diffUntracked(repo, 'new.txt');
      expect(diff, contains('+hello'));
      expect(diff, contains('/dev/null'));
    },
  );

  test('diffUntracked on a path git cannot read fails instead of returning an '
      'empty "successful" diff', () async {
    // A directory (or a vanished file) makes `git diff --no-index` exit 1
    // with an error on stderr and nothing on stdout — the same exit code as
    // a genuine diff. This must surface as a failure, not a blank pane.
    Directory('$repo/somedir').createSync();
    File('$repo/somedir/x.txt').writeAsStringSync('x\n');
    await expectLater(
      git.diffUntracked(repo, 'somedir/'),
      throwsA(isA<GitException>()),
    );
    await expectLater(
      git.diffUntracked(repo, 'no-such-file.txt'),
      throwsA(isA<GitException>()),
    );
  });

  test('an empty untracked file still reads as a diff, not an error', () async {
    // /dev/null vs an empty file: exit 1 with a header-only new-file diff on
    // stdout (verified against git 2.55) — content-empty but not
    // output-empty, so the empty-stdout error guard must not trip on it.
    File('$repo/empty.txt').writeAsStringSync('');
    final diff = await git.diffUntracked(repo, 'empty.txt');
    expect(diff, contains('new file mode'));
  });
}
