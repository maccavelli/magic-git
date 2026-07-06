// Integration coverage for GitService.validateLocalRepoRoot against REAL git
// repos (it shells out to `git rev-parse`). This is the local-backend guard
// that rejects a picked subdirectory / linked worktree / submodule whose real
// .git lives outside the macOS sandbox grant — plain validateRepoPath
// (--is-inside-work-tree) passes for all three, then every real read would fail
// with a raw permission error. connectLocal calls this right after
// validateRepoPath.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tmp;
  late GitService git;

  Future<void> git_(List<String> args, String cwd) async {
    final r = await Process.run('git', args, workingDirectory: cwd);
    if (r.exitCode != 0) {
      fail('git ${args.join(' ')} (in $cwd) failed: ${r.stderr}');
    }
  }

  Future<String> initRepo(String name) async {
    final dir = Directory('${tmp.path}/$name')..createSync(recursive: true);
    await git_(['init', '-q'], dir.path);
    await git_(['config', 'user.email', 't@t'], dir.path);
    await git_(['config', 'user.name', 't'], dir.path);
    await git_(['commit', '-q', '--allow-empty', '-m', 'init'], dir.path);
    return dir.path;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('validate_root_');
    git = GitService(LocalCommandExecutor());
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('accepts the repository top-level folder', () async {
    final root = await initRepo('main');
    await expectLater(git.validateLocalRepoRoot(root), completes);
  });

  test('rejects a subdirectory whose repo root is an ancestor', () async {
    final root = await initRepo('main');
    final sub = Directory('$root/sub/dir')..createSync(recursive: true);
    await expectLater(
      git.validateLocalRepoRoot(sub.path),
      throwsA(isA<GitException>()),
    );
  });

  test('rejects a linked worktree (git dir lives in the main repo)', () async {
    final root = await initRepo('main');
    final wt = '${tmp.path}/wt';
    await git_(['worktree', 'add', '-q', '--detach', wt, 'HEAD'], root);
    await expectLater(
      git.validateLocalRepoRoot(wt),
      throwsA(isA<GitException>()),
    );
  });
}
