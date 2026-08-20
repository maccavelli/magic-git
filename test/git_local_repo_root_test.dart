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

    final layout = await git.validateLocalRepoRoot(root);

    expect(layout, isNotNull);
    expect(layout!.isLinkedWorktree, isFalse);
    expect(layout.isSubmodule, isFalse);
  });

  test('rejects a subdirectory whose repo root is an ancestor', () async {
    final root = await initRepo('main');
    final sub = Directory('$root/sub/dir')..createSync(recursive: true);
    await expectLater(
      git.validateLocalRepoRoot(sub.path),
      throwsA(isA<GitException>()),
    );
  });

  test('ACCEPTS a linked worktree and reports where its main repo is', () async {
    // This used to be rejected outright. A linked worktree's git data does live
    // outside the picked folder — but unlike a submodule it is a first-class
    // checkout, and the main repo it points at is a real path we can ask the
    // user to grant. So classify it and let connectLocal take the second
    // security-scoped grant, rather than refusing the feature.
    final root = await initRepo('main');
    final wt = '${tmp.path}/wt';
    await git_(['worktree', 'add', '-q', '--detach', wt, 'HEAD'], root);

    final layout = await git.validateLocalRepoRoot(wt);

    expect(layout, isNotNull);
    expect(layout!.isLinkedWorktree, isTrue);
    expect(layout.isSubmodule, isFalse);
    // The second grant the sandbox needs — the main repo's working tree, whose
    // `.git` holds this worktree's HEAD/index and all the shared objects/refs.
    expect(layout.gitCommonDir, '${await _canon(root)}/.git');
    expect(layout.mainWorktreePath, await _canon(root));
  });

  test('still rejects a submodule, which has no grantable main repo', () async {
    // A submodule also uses a `.git` FILE, so "is .git a file" would have
    // misclassified it as a worktree. Its git dir equals its common dir
    // (`<super>/.git/modules/sub`), which is what separates the two.
    final superRepo = await initRepo('super');
    final child = await initRepo('child');
    await git_([
      '-c',
      'protocol.file.allow=always',
      'submodule',
      'add',
      '-q',
      child,
      'sub',
    ], superRepo);

    await expectLater(
      git.validateLocalRepoRoot('$superRepo/sub'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          contains('submodule'),
        ),
      ),
    );
  });
}

/// git reports symlink-resolved paths; on macOS the temp dir is under /var,
/// which is a symlink to /private/var.
Future<String> _canon(String path) => Directory(path).resolveSymbolicLinks();
