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
import 'package:remote_magic_git/core/exec/command_lanes.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart'
    show SSHCommandExecutor, SSHCommandResult;

/// Captures the lane and timeout each command was scheduled with — the one
/// thing the real-git tests above cannot see.
class _LaneCapturingExecutor extends LocalCommandExecutor {
  ExecLane? lastLane;
  Duration? lastTimeout;

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) async {
    lastLane = lane;
    lastTimeout = timeout;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

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

    test('move refuses a LOCKED worktree', () async {
      // Locking normally means the worktree lives on a volume that isn't always
      // mounted, so moving it out from under the lock is exactly what must not
      // happen silently. The UI surfaces this and offers to unlock.
      await git.addWorktree(repo, path: '$wtRoot/lk', newBranch: 'lk');
      await git.lockWorktree(repo, '$wtRoot/lk', reason: 'on a usb stick');

      await expectLater(
        git.moveWorktree(repo, '$wtRoot/lk', '$wtRoot/lk-moved'),
        throwsA(
          isA<GitException>().having(
            (e) => e.result.stderr,
            'stderr',
            contains('locked working tree'),
          ),
        ),
      );
      expect(Directory('$wtRoot/lk').existsSync(), isTrue);
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

    test('ARGLESS repair cannot fix a moved worktree — the path is required',
        () async {
      // Why the UI's per-row Repair must ask where the folder went: without an
      // operand, `git worktree repair` only re-checks the paths already on
      // record — and a moved folder is precisely what those don't cover. It
      // exits 0 having fixed nothing, so nothing throws; the entry just stays
      // prunable.
      await git.addWorktree(repo, path: '$wtRoot/n', newBranch: 'n');
      Directory('$wtRoot/n').renameSync('$wtRoot/n-moved');

      await git.repairWorktrees(repo);

      expect((await git.gitWorktrees(repo))[1].isPrunable, isTrue);
    });
  });

  group('copyIgnoredFiles', () {
    setUp(() async {
      // The thing `worktree add` leaves behind: gitignored config the project
      // needs to run at all.
      File('$repo/.gitignore').writeAsStringSync('.env\n.env.local\nbuild/\n');
      File('$repo/.env').writeAsStringSync('DATABASE_URL=postgres://dev\n');
      File('$repo/.env.local').writeAsStringSync('DEBUG=1\n');
      await raw(['add', '.gitignore']);
      await raw(['commit', '-q', '-m', 'ignore env']);
    });

    test('copies gitignored files INTO the worktree', () async {
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');
      // `worktree add` checks out tracked files only — so the new worktree is
      // missing .env and the project would fail on first run.
      expect(File('$wtRoot/w/.env').existsSync(), isFalse);

      await git.copyIgnoredFiles(
        from: repo,
        to: '$wtRoot/w',
        globs: ['.env*'],
      );

      expect(File('$wtRoot/w/.env').readAsStringSync(), contains('postgres'));
      expect(File('$wtRoot/w/.env.local').readAsStringSync(), contains('DEBUG'));
    });

    test('writes nothing into the SOURCE repo', () async {
      // The bug this pins: the destination came back from ShellEscaper already
      // single-quoted, and was then interpolated into a double-quoted shell
      // string — so the quotes became part of the path and `cp` created a
      // directory literally named `'` inside the source repo, with the .env
      // buried under it. The copy "succeeded" (exit 0) and the worktree was
      // empty, which is exactly why asserting on the exit code is not enough.
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');
      final before = Directory(repo).listSync().map((e) => e.path).toSet();

      await git.copyIgnoredFiles(
        from: repo,
        to: '$wtRoot/w',
        globs: ['.env*'],
      );

      final after = Directory(repo).listSync().map((e) => e.path).toSet();
      expect(
        after.difference(before),
        isEmpty,
        reason: 'copying into a worktree must not create anything in the repo',
      );
    });

    test('a destination path with spaces survives', () async {
      await git.addWorktree(repo, path: '$wtRoot/my worktree', newBranch: 'sp');

      await git.copyIgnoredFiles(
        from: repo,
        to: '$wtRoot/my worktree',
        globs: ['.env*'],
      );

      expect(File('$wtRoot/my worktree/.env').existsSync(), isTrue);
      expect(Directory(repo).listSync().map((e) => e.path), isNot(contains("'")));
    });

    test('a glob matching nothing is not an error', () async {
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');

      // A repo with no .env should still create a worktree.
      await expectLater(
        git.copyIgnoredFiles(
          from: repo,
          to: '$wtRoot/w',
          globs: ['.nothing-matches-this*'],
        ),
        completes,
      );
    });

    test('reports each copied file on stdout, for the Output view', () async {
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');

      final result = await git.copyIgnoredFiles(
        from: repo,
        to: '$wtRoot/w',
        globs: ['.env*'],
      );

      // The Output view is the only place a user can see that a glob quietly
      // matched nothing — so success must say what it did.
      expect(result.stdout, contains('copied .env'));
      expect(result.stdout, contains('copied .env.local'));
    });

    test('a failed copy FAILS the step, even when a later file succeeds',
        () async {
      // The bug this pins: the pipeline's exit status was the `while` loop's,
      // which is its LAST iteration's — so `.env` failing while `.env.local`
      // then copied fine reported overall success, and the worktree was
      // silently missing half its config.
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');
      // Make the FIRST file (ls-files output is sorted) uncopyable: cp opens
      // the destination for writing, and a read-only file refuses that.
      File('$wtRoot/w/.env').writeAsStringSync('stale\n');
      await Process.run('chmod', ['444', '$wtRoot/w/.env']);
      addTearDown(() => Process.run('chmod', ['644', '$wtRoot/w/.env']));

      await expectLater(
        git.copyIgnoredFiles(
          from: repo,
          to: '$wtRoot/w',
          globs: ['.env*'],
        ),
        throwsA(
          isA<GitException>().having(
            (e) => e.result.stderr,
            'stderr',
            contains('failed .env'),
          ),
        ),
      );
      // One bad file must not abandon the rest: the later one still arrived.
      expect(
        File('$wtRoot/w/.env.local').readAsStringSync(),
        contains('DEBUG'),
      );
    });

    test('a TRACKED file matching the glob is not copied over', () async {
      // `ls-files --others --ignored` only ever yields files git is deliberately
      // NOT tracking — which is exactly the set `worktree add` left behind. A
      // tracked file is already in the worktree, checked out by git.
      File('$repo/.env.example').writeAsStringSync('DATABASE_URL=\n');
      await raw(['add', '-f', '.env.example']);
      await raw(['commit', '-q', '-m', 'add example']);
      await git.addWorktree(repo, path: '$wtRoot/w', newBranch: 'w');
      File('$wtRoot/w/.env.example').writeAsStringSync('EDITED LOCALLY\n');

      await git.copyIgnoredFiles(
        from: repo,
        to: '$wtRoot/w',
        globs: ['.env*'],
      );

      // The tracked one is untouched; only the ignored ones came across.
      expect(
        File('$wtRoot/w/.env.example').readAsStringSync(),
        'EDITED LOCALLY\n',
      );
      expect(File('$wtRoot/w/.env').existsSync(), isTrue);
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

  group('runInWorktree scheduling', () {
    test('the post-create hook runs OUTSIDE the exclusive barrier', () async {
      // A hook is minutes long by nature (`pnpm install`). On the exclusive
      // lane it was a barrier: every background refresh in the app queued
      // behind the install. It operates on a brand-new checkout nothing else
      // touches, which is exactly what ExecLane.isolated is for — and it gets
      // the hook timeout, because a cold-cache install legitimately outlives
      // the 5-minute mutation ceiling.
      final exec = _LaneCapturingExecutor();
      final capturing = GitService(exec);

      await capturing.runInWorktree('/wt', 'pnpm install');

      expect(exec.lastLane, ExecLane.isolated);
      expect(exec.lastTimeout, GitService.defaultHookTimeout);
    });
  });
}
