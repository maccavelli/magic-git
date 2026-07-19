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

  // The direct `_executor.execute` sites used to bypass the scope registry
  // entirely — every read below failed with "not a git repository" on a
  // scoped repo even though funneled commands (commit, branch…) worked.
  // Each test here proves one representative site now carries the scope.
  group('direct-execute sites carry the scope', () {
    setUp(() {
      git.registerRepoScope(workTree, gitDir: bareDir, workTree: workTree);
    });

    test('validateRepoPath accepts the scoped repo', () async {
      await git.validateRepoPath(workTree); // must not throw
    });

    test('the status snapshot sees a work-tree edit', () async {
      File('$workTree/.testrc').writeAsStringSync('export EDITOR=emacs\n');
      final status = await git.status(workTree);
      expect(
        status.files.any((f) => f.path == '.testrc'),
        isTrue,
        reason: 'snapshot should list the modified tracked file: '
            '${status.files.map((f) => f.path)}',
      );
    });

    test('log returns the seeded history', () async {
      final commits = await git.log(workTree);
      expect(commits, hasLength(1));
      expect(commits.single.subject, 'seed dotfiles');
    });

    test('diffFile shows a work-tree modification', () async {
      File('$workTree/.testrc').writeAsStringSync('export EDITOR=emacs\n');
      final diff = await git.diffFile(
        workTree,
        path: '.testrc',
        staged: false,
      );
      expect(diff, contains('+export EDITOR=emacs'));
    });

    test('revParse and reflog resolve', () async {
      expect(await git.revParse(workTree, 'HEAD'), isNotNull);
      expect(await git.reflog(workTree), isNotEmpty);
    });

    test('stash list/show read a seeded stash', () async {
      File('$workTree/.testrc').writeAsStringSync('export EDITOR=nano\n');
      await seed(['stash', 'push', '-m', 'wip']);
      final stashes = await git.stashList(workTree);
      expect(stashes, hasLength(1));
      final patch = await git.stashShow(workTree, stashes.single.oid);
      expect(patch, contains('+export EDITOR=nano'));
    });

    test('checkIgnore consults the scoped repo\'s ignore rules', () async {
      File('$workTree/.gitignore').writeAsStringSync('ignored.txt\n');
      final ignored = await git.checkIgnore(
        workTree,
        ['ignored.txt', 'kept.txt'],
      );
      expect(ignored, {'ignored.txt'});
    });
  });

  test('setFsmonitorMany pins each repo\'s scope to its own subshell',
      () async {
    git.registerRepoScope(workTree, gitDir: bareDir, workTree: workTree);
    // A second, ordinary repo in the same sweep. The scoped repo goes FIRST —
    // the leak geometry: _run funnels the combined script under the first
    // repo's path, whose GIT_DIR overlay (env beats cwd discovery) used to
    // send EVERY repo's `git config` write into the scoped repo's git-dir.
    final root = tempDir.resolveSymbolicLinksSync();
    final plainDir = Directory('$root/plain')..createSync();
    final plain = plainDir.resolveSymbolicLinksSync();
    final init = await Process.run('git', ['init', plain]);
    expect(init.exitCode, 0, reason: init.stderr.toString());

    final result = await git.setFsmonitorMany(
      [workTree, plain],
      enabled: true,
    );
    expect(result.stderr, isNot(contains('fsmonitor setup failed')));

    // Each repo's write landed in its OWN config: the bare git-dir for the
    // scoped repo, `.git/config` for the plain one (which stayed empty under
    // the leak).
    final scoped = await Process.run(
      'git',
      ['--git-dir', bareDir, 'config', '--get', 'core.untrackedCache'],
    );
    expect((scoped.stdout as String).trim(), 'true');
    final plainVal = await Process.run(
      'git',
      ['-C', plain, 'config', '--get', 'core.untrackedCache'],
    );
    expect((plainVal.stdout as String).trim(), 'true');
  });
}
