// `rebaseOnto` against real git: the plain non-interactive rebase a
// drag-a-branch-onto-a-commit gesture performs. Unit tests pin argv; only real
// git pins that the current branch actually replays on top of the target and
// that a completed rebase leaves an undoable HEAD move.
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

  Future<String> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  void write(String name, String contents) =>
      File('$repo/$name').writeAsStringSync(contents);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('rebase_onto_');
    repo = tempDir.resolveSymbolicLinksSync();
    git = GitService(LocalCommandExecutor());

    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);
    write('base.txt', 'base\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'base']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('rebaseOnto replays the current branch on top of the target', () async {
    // feature forks from base and adds two commits touching feature.txt.
    await raw(['checkout', '-q', '-b', 'feature']);
    write('feature.txt', 'f1\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'F1']);
    write('feature.txt', 'f1\nf2\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'F2']);

    // main advances independently, touching a different file (no conflict).
    await raw(['checkout', '-q', 'main']);
    write('main.txt', 'm1\n');
    await raw(['add', '-A']);
    await raw(['commit', '-q', '-m', 'M1']);
    final mainTip = await raw(['rev-parse', 'main']);

    await raw(['checkout', '-q', 'feature']);
    final before = await raw(['rev-parse', 'HEAD']);

    final result = await git.rebaseOnto(repo, 'main');
    expect(result.exitCode, 0, reason: result.stderr);

    // feature now descends from main's tip.
    expect(await raw(['merge-base', 'feature', 'main']), mainTip);
    // HEAD moved (the rebase rewrote the two feature commits).
    expect(await raw(['rev-parse', 'HEAD']), isNot(before));
    // The two feature commits sit above M1, newest first.
    final subjects = (await raw(['log', '--format=%s', 'feature'])).split('\n');
    expect(subjects.take(3).toList(), ['F2', 'F1', 'M1']);
    // The rebased tree carries both files.
    expect(File('$repo/feature.txt').existsSync(), isTrue);
    expect(File('$repo/main.txt').existsSync(), isTrue);
  });

  test('rebaseOnto onto current HEAD is a no-op', () async {
    // Rebasing a branch onto a commit it already descends from moves nothing.
    final before = await raw(['rev-parse', 'HEAD']);
    final result = await git.rebaseOnto(repo, 'HEAD');
    expect(result.exitCode, 0, reason: result.stderr);
    expect(await raw(['rev-parse', 'HEAD']), before);
  });
}
