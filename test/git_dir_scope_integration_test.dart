// Prototype: prove the GIT_DIR/GIT_WORK_TREE scoping seam against real git.
//
// The bare-dotfiles pattern is a bare repo (e.g. `~/.home.git`) whose work
// tree is a plain directory with no `.git` in it (e.g. `$HOME`). Git's normal
// discovery — walk up from the process's working directory to a `.git` — finds
// nothing there, so every command fails. The canonical workaround is the
// `git --git-dir=<bare> --work-tree=<home> …` alias, whose environment form is
// `GIT_DIR` / `GIT_WORK_TREE`.
//
// This exercises [GitService.registerRepoScope]: one registration makes every
// command GitService issues for that repoPath carry those two env vars through
// the executor seam (`_run` → CommandExecutor.execute → Process.start's
// `environment:`). The proof is that the *identical* GitService read
//   * throws for the unscoped work tree (git can't find a repository), and
//   * succeeds once scoped, resolving the bare git-dir and the separate work
//     tree — values only git-with-the-env could report — and even reports the
//     repository as bare.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tempDir;
  late String workTree; // the "home" — a plain dir, no `.git` inside it
  late String bareDir; // the bare repo — git-dir living outside the work tree
  late GitService git;

  // Runs a real git command with the bare-repo scope set in the environment —
  // used only to SEED the fixture, independent of the code under test.
  Future<void> seed(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: workTree,
      environment: {'GIT_DIR': bareDir, 'GIT_WORK_TREE': workTree},
    );
    expect(
      result.exitCode,
      0,
      reason: 'seed `git ${args.join(' ')}` failed: ${result.stderr}',
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('magic_git_scope_');
    // Symlink-resolve up front so comparisons hold on macOS, where the temp
    // dir lives under /var/folders (a symlink to /private/var/folders) and
    // git's `--path-format=absolute` resolves the real path.
    final root = tempDir.resolveSymbolicLinksSync();
    final home = Directory('$root/home')..createSync();
    workTree = home.resolveSymbolicLinksSync();
    bareDir = '$root/home.git';

    // A bare repo with a separate work tree, and one seeded commit — exactly
    // the dotfiles geometry.
    final init = await Process.run('git', ['init', '--bare', bareDir]);
    expect(init.exitCode, 0, reason: init.stderr.toString());
    bareDir = Directory(bareDir).resolveSymbolicLinksSync();
    File('$workTree/.testrc').writeAsStringSync('export EDITOR=vim\n');
    await seed(['add', '.testrc']);
    await seed([
      '-c', 'user.email=t@example.com',
      '-c', 'user.name=Test',
      'commit', '-m', 'seed dotfiles',
    ]);

    git = GitService(LocalCommandExecutor());
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('unscoped work tree is not a repository — the read fails', () async {
    // No scope registered: git discovers from the working directory (the work
    // tree), finds no `.git`, and the command fails.
    await expectLater(
      git.repoLayout(workTree),
      throwsA(isA<GitException>()),
    );
  });

  test('a registered scope routes GIT_DIR/GIT_WORK_TREE through the executor',
      () async {
    git.registerRepoScope(workTree, gitDir: bareDir, workTree: workTree);

    // repoLayout runs `rev-parse --show-toplevel --git-dir …`; it can only
    // succeed — and echo these exact paths — if both env vars reached git.
    final layout = await git.repoLayout(workTree);
    expect(layout.gitDir, bareDir, reason: 'GIT_DIR did not reach git');
    expect(layout.toplevel, workTree, reason: 'GIT_WORK_TREE did not reach git');

    // A second, content-level read through the same seam: `worktree list`
    // reports the repository as bare — proving we are genuinely operating the
    // bare repo, not merely echoing paths back.
    final worktrees = await git.gitWorktrees(workTree);
    expect(
      worktrees.any((w) => w.isBare),
      isTrue,
      reason: 'expected the scoped repo to be reported as bare: $worktrees',
    );
  });

  test('unregistering the scope reverts to working-directory discovery',
      () async {
    git.registerRepoScope(workTree, gitDir: bareDir, workTree: workTree);
    await git.repoLayout(workTree); // succeeds while scoped

    git.unregisterRepoScope(workTree);
    await expectLater(
      git.repoLayout(workTree),
      throwsA(isA<GitException>()),
      reason: 'scope should no longer be injected after unregister',
    );
  });
}
