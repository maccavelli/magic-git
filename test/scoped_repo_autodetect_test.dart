// Auto-detecting the scoped/dotfiles shape from a folder, so the add sheet can
// pre-fill its toggle + git-dir without the user typing anything.
//
// The key case is the one git can discover on its own: a `--separate-git-dir`
// / gitfile-redirect repo (a `.git` FILE in the work tree pointing at an
// out-of-tree git-dir, honoring `core.worktree`) — exactly the user's
// `~/.home.git` setup. `git rev-parse` follows the redirect with NO env
// injection, so [GitService.repoLayout] resolves it unscoped and
// [isScopedRepoLayout] recognizes the external git-dir. Ordinary repos and
// linked worktrees must NOT be mistaken for it.
//
// A `.git` redirect to a **bare** git-dir (`git init --bare ~/.home.git` +
// a hand-written gitfile — no `core.worktree`) is the shape native discovery
// CANNOT resolve: bare means no work tree, so `--show-toplevel` dies. The
// fallback pair [GitService.gitfileRedirectTarget] +
// [GitService.scopedRepoLayout] covers it — the redirect names the candidate
// git-dir and the env-overlay probe validates it, exactly the environment the
// eventual scope registration injects.
//
// (A bare git-dir with NO `.git` redirect at all remains undetectable from
// the tree — auto-detect falls back to the manual toggle. That geometry is
// proven in git_dir_scope_integration_test.dart.)
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/connection/local_repo_form.dart';

void main() {
  group('isScopedRepoLayout (pure)', () {
    test('ordinary <toplevel>/.git is not scoped', () {
      expect(
        isScopedRepoLayout(
          const RepoLayout(
            toplevel: '/home/u/proj',
            gitDir: '/home/u/proj/.git',
            gitCommonDir: '/home/u/proj/.git',
          ),
        ),
        isFalse,
      );
    });

    test('an out-of-tree git-dir (dotfiles redirect / bare) is scoped', () {
      expect(
        isScopedRepoLayout(
          const RepoLayout(
            toplevel: '/home/u',
            gitDir: '/home/u/.home.git',
            gitCommonDir: '/home/u/.home.git',
          ),
        ),
        isTrue,
      );
    });

    test('a linked worktree is not treated as scoped', () {
      expect(
        isScopedRepoLayout(
          const RepoLayout(
            toplevel: '/home/u/wt',
            gitDir: '/home/u/main/.git/worktrees/wt',
            gitCommonDir: '/home/u/main/.git',
          ),
        ),
        isFalse,
      );
    });

    test('a submodule is not treated as scoped', () {
      expect(
        isScopedRepoLayout(
          const RepoLayout(
            toplevel: '/home/u/super/sub',
            gitDir: '/home/u/super/.git/modules/sub',
            gitCommonDir: '/home/u/super/.git/modules/sub',
          ),
        ),
        isFalse,
      );
    });
  });

  group('against real git', () {
    late Directory tempDir;
    late String root;
    late GitService git;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('magic_git_detect_');
      // Symlink-resolve up front: macOS temp lives under /var → /private/var,
      // and git's --path-format=absolute reports the resolved path.
      root = tempDir.resolveSymbolicLinksSync();
      git = GitService(LocalCommandExecutor());
    });

    tearDown(() async {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<void> run(
      List<String> args, {
      required String cwd,
      Map<String, String>? env,
    }) async {
      final r = await Process.run(
        'git',
        args,
        workingDirectory: cwd,
        environment: env,
      );
      expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
    }

    test(
      'a --separate-git-dir repo is discovered unscoped and detected as scoped, '
      'with the external git-dir as its common dir',
      () async {
        final work = Directory('$root/home')..createSync();
        final workTree = work.resolveSymbolicLinksSync();
        final external = '$root/home.git';
        // A `.git` FILE in the work tree redirects to the out-of-tree git-dir —
        // the shape git resolves natively (like ~/.home.git).
        await run([
          'init',
          '--separate-git-dir=$external',
          workTree,
        ], cwd: root);
        final gitDir = Directory(external).resolveSymbolicLinksSync();

        // Unscoped repoLayout: no GIT_DIR registered — pure native discovery.
        final layout = await git.repoLayout(workTree);
        expect(layout.toplevel, workTree);
        expect(layout.gitCommonDir, gitDir);
        expect(isScopedRepoLayout(layout), isTrue);
      },
    );

    test('an ordinary repo is not detected as scoped', () async {
      final dir = Directory('$root/plain')..createSync();
      final repo = dir.resolveSymbolicLinksSync();
      await run(['init', repo], cwd: root);

      final layout = await git.repoLayout(repo);
      expect(layout.gitCommonDir, '$repo/.git');
      expect(isScopedRepoLayout(layout), isFalse);
    });

    test(
      'a bare git-dir behind a .git gitfile redirect: native discovery fails, '
      'the redirect fallback resolves it as scoped',
      () async {
        // The user-reported geometry: the picked folder holds a hand-written
        // `.git` redirect file plus the bare `.home.git` it points at.
        final work = Directory('$root/home')..createSync();
        final workTree = work.resolveSymbolicLinksSync();
        await run(['init', '--bare', '$workTree/.home.git'], cwd: root);
        final bare = Directory(
          '$workTree/.home.git',
        ).resolveSymbolicLinksSync();
        File('$workTree/.git').writeAsStringSync('gitdir: $bare\n');

        // The premise: `git init --bare` sets core.bare=true and writes no
        // core.worktree, so native discovery has no work tree to report.
        await expectLater(
          git.repoLayout(workTree),
          throwsA(isA<GitException>()),
        );

        // The fallback: the gitfile names the candidate git-dir…
        expect(await git.gitfileRedirectTarget(workTree), bare);
        // …and the env-overlay probe validates it as the scoped layout.
        final layout = await git.scopedRepoLayout(workTree, gitDir: bare);
        expect(layout.toplevel, workTree);
        expect(layout.gitCommonDir, bare);
        expect(isScopedRepoLayout(layout), isTrue);
      },
    );

    test(
      'a relative gitfile redirect resolves against the work tree',
      () async {
        final work = Directory('$root/home')..createSync();
        final workTree = work.resolveSymbolicLinksSync();
        await run(['init', '--bare', '$workTree/.home.git'], cwd: root);
        final bare = Directory(
          '$workTree/.home.git',
        ).resolveSymbolicLinksSync();
        File('$workTree/.git').writeAsStringSync('gitdir: ./.home.git\n');

        final target = await git.gitfileRedirectTarget(workTree);
        expect(target, '$workTree/.home.git');
        final layout = await git.scopedRepoLayout(workTree, gitDir: target!);
        expect(layout.gitCommonDir, bare);
        expect(isScopedRepoLayout(layout), isTrue);
      },
    );

    test(
      'gitfileRedirectTarget is null for an ordinary repo and a non-repo',
      () async {
        final dir = Directory('$root/plain')..createSync();
        final repo = dir.resolveSymbolicLinksSync();
        await run(['init', repo], cwd: root);
        // `.git` is a directory — not a redirect.
        expect(await git.gitfileRedirectTarget(repo), isNull);

        final empty = Directory('$root/empty')..createSync();
        expect(
          await git.gitfileRedirectTarget(empty.resolveSymbolicLinksSync()),
          isNull,
        );
      },
    );

    test(
      'detectRepoLayout resolves every supported shape through one call',
      () async {
        // Native shape (--separate-git-dir writes core.worktree).
        final sep = Directory('$root/sep')..createSync();
        final sepTree = sep.resolveSymbolicLinksSync();
        await run([
          'init',
          '--separate-git-dir=$root/sep.git',
          sepTree,
        ], cwd: root);
        expect(
          isScopedRepoLayout((await git.detectRepoLayout(sepTree))!),
          isTrue,
        );

        // Fallback shape (bare + hand-written redirect).
        final work = Directory('$root/home')..createSync();
        final workTree = work.resolveSymbolicLinksSync();
        await run(['init', '--bare', '$workTree/.home.git'], cwd: root);
        File('$workTree/.git').writeAsStringSync('gitdir: ./.home.git\n');
        final layout = await git.detectRepoLayout(workTree);
        expect(layout, isNotNull);
        expect(isScopedRepoLayout(layout!), isTrue);

        // Not a repo at all.
        final empty = Directory('$root/none')..createSync();
        expect(
          await git.detectRepoLayout(empty.resolveSymbolicLinksSync()),
          isNull,
        );
      },
    );

    test(
      'detectRepoLayout survives a poisoned scope registry (work tree mapped '
      'to itself)',
      () async {
        // The real-world poison: an earlier add accepted the WORK TREE as the
        // git-dir and persisted it; on connect that scope is registered, and
        // every funneled command — including the native-discovery probe —
        // inherits GIT_DIR=<worktree>, which is fatal. The redirect fallback
        // must still resolve the truth.
        final work = Directory('$root/home')..createSync();
        final workTree = work.resolveSymbolicLinksSync();
        await run(['init', '--bare', '$workTree/.home.git'], cwd: root);
        final bare = Directory(
          '$workTree/.home.git',
        ).resolveSymbolicLinksSync();
        File('$workTree/.git').writeAsStringSync('gitdir: $bare\n');

        git.registerRepoScope(workTree, gitDir: workTree, workTree: workTree);
        // The premise: the poisoned env breaks the native probe.
        await expectLater(
          git.repoLayout(workTree),
          throwsA(isA<GitException>()),
        );

        final layout = await git.detectRepoLayout(workTree);
        expect(layout, isNotNull);
        expect(layout!.gitCommonDir, bare);
        expect(isScopedRepoLayout(layout), isTrue);
      },
    );

    test(
      'a garbage redirect target fails the probe instead of mis-detecting',
      () async {
        final work = Directory('$root/home')..createSync();
        final workTree = work.resolveSymbolicLinksSync();
        File('$workTree/.git').writeAsStringSync('gitdir: $root/nowhere.git\n');

        expect(await git.gitfileRedirectTarget(workTree), '$root/nowhere.git');
        await expectLater(
          git.scopedRepoLayout(workTree, gitDir: '$root/nowhere.git'),
          throwsA(isA<GitException>()),
        );
      },
    );

    test('a linked worktree is not detected as scoped', () async {
      final mainDir = Directory('$root/main')..createSync();
      final main = mainDir.resolveSymbolicLinksSync();
      await run(['init', main], cwd: root);
      File('$main/f').writeAsStringSync('x\n');
      await run(['add', 'f'], cwd: main);
      await run([
        '-c',
        'user.email=t@example.com',
        '-c',
        'user.name=Test',
        'commit',
        '-m',
        'seed',
      ], cwd: main);
      final wt = '$root/wt';
      await run(['worktree', 'add', wt], cwd: main);

      final layout = await git.repoLayout(
        Directory(wt).resolveSymbolicLinksSync(),
      );
      expect(layout.isLinkedWorktree, isTrue);
      expect(isScopedRepoLayout(layout), isFalse);
    });
  });
}
