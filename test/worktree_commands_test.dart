// End-to-end `git worktree` against real git in scratch repos
// (LocalCommandExecutor — same honest-test rationale as undo_scripts_test.dart):
// the porcelain parser must survive real output, and the add/remove/lock/prune
// argv must be accepted by a real git. Mocks would have hidden that
// `git worktree add` rejects `--end-of-options` while every other subcommand
// accepts it.
//
// About `git worktree`, NOT the working tree — see worktree_invalidation_test
// and worktree_cache_staleness_test for that unrelated meaning of the word.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tempDir;
  late String repo;
  late GitService git;

  /// Where linked worktrees go — a sibling of the repo, never inside it.
  late String wtRoot;

  Future<String> raw(List<String> args, {String? cwd}) async {
    final result = await Process.run('git', args, workingDirectory: cwd ?? repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('worktree_cmds_test_');
    // Resolve symlinks up front: on macOS the temp dir is under /var, which is
    // a symlink to /private/var. Git realpath's every path it reports, so
    // without this the paths git returns would never string-match ours.
    repo = '${tempDir.resolveSymbolicLinksSync()}/main';
    wtRoot = '${tempDir.resolveSymbolicLinksSync()}/wts';
    Directory(repo).createSync(recursive: true);
    Directory(wtRoot).createSync(recursive: true);
    git = GitService(LocalCommandExecutor());

    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Test']);
    await raw(['config', 'user.email', 'test@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    File('$repo/a.txt').writeAsStringSync('one\n');
    await raw(['add', 'a.txt']);
    await raw(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('repoLayout', () {
    test('main worktree: git dir equals common dir', () async {
      final layout = await git.repoLayout(repo);

      expect(layout.toplevel, repo);
      expect(layout.gitDir, '$repo/.git');
      expect(layout.gitCommonDir, '$repo/.git');
      expect(layout.isLinkedWorktree, isFalse);
      expect(layout.mainWorktreePath, repo);
    });

    test('linked worktree points back at the main repo', () async {
      await git.addWorktree(repo, path: '$wtRoot/feat', newBranch: 'feat');

      final layout = await git.repoLayout('$wtRoot/feat');

      expect(layout.toplevel, '$wtRoot/feat');
      // The whole basis of the sandbox work: the git dir lives under the MAIN
      // repo, not under the worktree we opened.
      expect(layout.gitDir, '$repo/.git/worktrees/feat');
      expect(layout.gitCommonDir, '$repo/.git');
      expect(layout.isLinkedWorktree, isTrue);
      expect(layout.isSubmodule, isFalse);
      expect(layout.mainWorktreePath, repo);
    });
  });

  group('add', () {
    test('creates a worktree on a new branch and lists it', () async {
      await git.addWorktree(repo, path: '$wtRoot/feat', newBranch: 'feat');

      expect(File('$wtRoot/feat/a.txt').existsSync(), isTrue);
      // A linked worktree's `.git` is a FILE, not a directory — this is why a
      // recursive watch of it sees no ref/HEAD changes.
      expect(FileSystemEntity.isFileSync('$wtRoot/feat/.git'), isTrue);

      final wts = await git.gitWorktrees(repo);
      expect(wts, hasLength(2));
      expect(wts.first.isMain, isTrue);
      expect(wts.first.path, repo);
      expect(wts[1].path, '$wtRoot/feat');
      expect(wts[1].branch, 'refs/heads/feat');
      expect(wts[1].isMain, isFalse);
      expect(wts[1].name, 'feat');
    });

    test('checks out an existing branch', () async {
      await raw(['branch', 'existing']);

      await git.addWorktree(repo, path: '$wtRoot/e', commitish: 'existing');

      final wts = await git.gitWorktrees(repo);
      expect(wts[1].branch, 'refs/heads/existing');
    });

    test('--detach produces a detached worktree', () async {
      await git.addWorktree(repo, path: '$wtRoot/det', detach: true);

      final wt = (await git.gitWorktrees(repo))[1];
      expect(wt.isDetached, isTrue);
      expect(wt.branch, isNull);
      expect(wt.branchLabel, startsWith('(detached '));
    });

    test('--lock with a reason is atomic with creation', () async {
      await git.addWorktree(
        repo,
        path: '$wtRoot/l',
        newBranch: 'l',
        lock: true,
        lockReason: 'usb drive',
      );

      final wt = (await git.gitWorktrees(repo))[1];
      expect(wt.isLocked, isTrue);
      expect(wt.lockReason, 'usb drive');
    });

    test('refuses a branch already checked out in another worktree', () async {
      await git.addWorktree(repo, path: '$wtRoot/one', newBranch: 'shared');

      // git's own guard; the UI surfaces this instead of pre-empting it.
      await expectLater(
        git.addWorktree(repo, path: '$wtRoot/two', commitish: 'shared'),
        throwsA(
          isA<GitException>().having(
            (e) => e.result.stderr,
            'stderr',
            contains('already used by worktree'),
          ),
        ),
      );
    });

    test('rejects a path starting with "-" rather than misparsing it', () {
      // `git worktree add` accepts neither `--end-of-options` nor `--`, so a
      // leading dash would be read as a flag. Fail loudly instead.
      expect(
        () => git.addWorktree(repo, path: '-oops', newBranch: 'x'),
        throwsArgumentError,
      );
    });
  });

  group('remove', () {
    test('deletes the directory and the admin entry', () async {
      await git.addWorktree(repo, path: '$wtRoot/gone', newBranch: 'gone');
      expect(Directory('$wtRoot/gone').existsSync(), isTrue);

      await git.removeWorktree(repo, '$wtRoot/gone');

      expect(Directory('$wtRoot/gone').existsSync(), isFalse);
      expect(Directory('$repo/.git/worktrees/gone').existsSync(), isFalse);
      expect(await git.gitWorktrees(repo), hasLength(1));
    });

    test('refuses a dirty worktree unless forced', () async {
      await git.addWorktree(repo, path: '$wtRoot/d', newBranch: 'd');
      File('$wtRoot/d/untracked.txt').writeAsStringSync('x');

      await expectLater(
        git.removeWorktree(repo, '$wtRoot/d'),
        throwsA(isA<GitException>()),
      );
      expect(Directory('$wtRoot/d').existsSync(), isTrue);

      await git.removeWorktree(repo, '$wtRoot/d', force: true);
      expect(Directory('$wtRoot/d').existsSync(), isFalse);
    });

    test('a locked worktree needs force TWICE', () async {
      await git.addWorktree(repo, path: '$wtRoot/lk', newBranch: 'lk');
      await git.lockWorktree(repo, '$wtRoot/lk', reason: 'pinned');

      // A single --force is not enough for a locked worktree.
      await expectLater(
        git.removeWorktree(repo, '$wtRoot/lk', force: true),
        throwsA(isA<GitException>()),
      );

      // force + locked emits --force twice, which git requires.
      await git.removeWorktree(repo, '$wtRoot/lk', force: true, locked: true);
      expect(Directory('$wtRoot/lk').existsSync(), isFalse);
    });

    test('never removes the main worktree', () async {
      await expectLater(
        git.removeWorktree(repo, repo),
        throwsA(isA<GitException>()),
      );
      expect(Directory(repo).existsSync(), isTrue);
    });
  });

  group('lock / unlock', () {
    test('round-trips, and a reasonless lock reports an empty reason', () async {
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');

      await git.lockWorktree(repo, '$wtRoot/w');
      var wt = (await git.gitWorktrees(repo))[1];
      expect(wt.isLocked, isTrue);
      expect(wt.lockReason, isEmpty);

      await git.unlockWorktree(repo, '$wtRoot/w');
      wt = (await git.gitWorktrees(repo))[1];
      expect(wt.isLocked, isFalse);
    });
  });

  group('prune', () {
    test('a deleted directory becomes prunable, and prune forgets it', () async {
      await git.addWorktree(repo, path: '$wtRoot/zap', newBranch: 'zap');
      Directory('$wtRoot/zap').deleteSync(recursive: true);

      final before = (await git.gitWorktrees(repo))[1];
      expect(before.isPrunable, isTrue);
      expect(before.prunableReason, contains('non-existent'));

      // --dry-run reports without forgetting, so the UI can preview.
      final preview = await git.pruneWorktrees(repo, dryRun: true);
      expect(preview.join('\n'), contains('zap'));
      expect(await git.gitWorktrees(repo), hasLength(2));

      final pruned = await git.pruneWorktrees(repo);
      expect(pruned.join('\n'), contains('zap'));
      expect(await git.gitWorktrees(repo), hasLength(1));
    });

    test('a locked worktree is never prunable, even when missing', () async {
      await git.addWorktree(repo, path: '$wtRoot/keep', newBranch: 'keep');
      await git.lockWorktree(repo, '$wtRoot/keep', reason: 'on a usb stick');
      Directory('$wtRoot/keep').deleteSync(recursive: true);

      // This is the entire point of lock: gc must not reap a worktree whose
      // removable volume is merely unmounted.
      expect((await git.gitWorktrees(repo))[1].isPrunable, isFalse);
      await git.pruneWorktrees(repo);
      expect(await git.gitWorktrees(repo), hasLength(2));
    });
  });

  group('move / repair', () {
    test('move relocates the worktree and rewrites both link halves', () async {
      await git.addWorktree(repo, path: '$wtRoot/m', newBranch: 'm');

      await git.moveWorktree(repo, '$wtRoot/m', '$wtRoot/moved');

      expect(Directory('$wtRoot/m').existsSync(), isFalse);
      final wt = (await git.gitWorktrees(repo))[1];
      expect(wt.path, '$wtRoot/moved');
      // The link is intact in both directions, so git still works from inside.
      final layout = await git.repoLayout('$wtRoot/moved');
      expect(layout.gitCommonDir, '$repo/.git');
    });

    test('repair re-links a worktree moved behind git\'s back', () async {
      await git.addWorktree(repo, path: '$wtRoot/r', newBranch: 'r');

      // Simulate the user dragging the folder in Finder.
      Directory('$wtRoot/r').renameSync('$wtRoot/r-moved');
      expect((await git.gitWorktrees(repo))[1].isPrunable, isTrue);

      await git.repairWorktrees(repo, ['$wtRoot/r-moved']);

      final wt = (await git.gitWorktrees(repo))[1];
      expect(wt.isPrunable, isFalse);
      expect(wt.path, '$wtRoot/r-moved');
    });
  });

  group('branch occupancy via %(worktreepath)', () {
    test('reports which worktree holds each branch, including the current one',
        () async {
      await git.addWorktree(repo, path: '$wtRoot/feat', newBranch: 'feat');
      await raw(['branch', 'idle']);

      final refs = await git.refs(repo);
      GitRef byName(String n) =>
          refs.firstWhere((r) => r.name == 'refs/heads/$n');

      // Checked out in a linked worktree.
      expect(byName('feat').worktreePath, '$wtRoot/feat');
      expect(byName('feat').isHead, isFalse);

      // Checked out HERE. git's docs claim worktreepath is only set for linked
      // worktrees; it is in fact set for this one too, so worktreePath alone
      // cannot mean "checked out elsewhere" — compare it against the toplevel.
      expect(byName('main').worktreePath, repo);
      expect(byName('main').isHead, isTrue);

      // Not checked out anywhere.
      expect(byName('idle').worktreePath, isNull);
    });

    test('still reports a worktree whose directory was deleted', () async {
      await git.addWorktree(repo, path: '$wtRoot/ghost', newBranch: 'ghost');
      Directory('$wtRoot/ghost').deleteSync(recursive: true);

      // git keeps the association until prune runs, so the UI must not assume
      // a worktreePath exists on disk.
      final refs = await git.refs(repo);
      final ghost = refs.firstWhere((r) => r.name == 'refs/heads/ghost');
      expect(ghost.worktreePath, '$wtRoot/ghost');
      expect(Directory(ghost.worktreePath!).existsSync(), isFalse);
    });
  });
}
