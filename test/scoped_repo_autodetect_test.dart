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
// (The pure-bare pattern — a bare git-dir with no `.git` in the work tree — is
// intentionally NOT covered here: git can't discover it from the tree, so
// auto-detect falls back to the manual toggle. That geometry is proven in
// git_dir_scope_integration_test.dart.)
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
        await run(
          ['init', '--separate-git-dir=$external', workTree],
          cwd: root,
        );
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

    test('a linked worktree is not detected as scoped', () async {
      final mainDir = Directory('$root/main')..createSync();
      final main = mainDir.resolveSymbolicLinksSync();
      await run(['init', main], cwd: root);
      File('$main/f').writeAsStringSync('x\n');
      await run(['add', 'f'], cwd: main);
      await run([
        '-c', 'user.email=t@example.com',
        '-c', 'user.name=Test',
        'commit', '-m', 'seed',
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
