// probeLocalRepo classifies a local folder by reading its `.git` entry directly,
// with NO git invocation — which is the point: under the macOS App Sandbox a
// linked worktree cannot run git at all until we hold a grant on its MAIN
// repository, and we can't know to ask for that grant until we've classified the
// folder. The `.git` file lives inside the grant we already have, so reading it
// breaks the cycle.
//
// Run against real git layouts, since the whole value is matching what git
// actually writes.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/local/linked_worktree_probe.dart';

void main() {
  late Directory tmp;
  late String root;

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
    tmp = await Directory.systemTemp.createTemp('wt_probe_');
    root = await initRepo('main');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('an ordinary repo has a .git DIRECTORY', () async {
    final probe = probeLocalRepo(root);

    expect(probe.kind, LocalRepoKind.ordinary);
    expect(probe.worktree, isNull);
  });

  test('a linked worktree resolves back to its main repository', () async {
    final wt = '${tmp.path}/feature';
    await git_(['worktree', 'add', '-q', wt, '-b', 'feature'], root);

    final probe = probeLocalRepo(wt);

    expect(probe.kind, LocalRepoKind.linkedWorktree);
    // This is the folder that needs the second security-scoped grant.
    expect(probe.worktree!.mainRepoPath, await _canon(root));
    expect(
      probe.worktree!.gitDir,
      '${await _canon(root)}/.git/worktrees/feature',
    );
  });

  test('a worktree with a RELATIVE gitdir resolves too', () async {
    // git 2.48+ can write `gitdir: ../../main/.git/worktrees/x` instead of an
    // absolute path (`worktree.useRelativePaths`). Tower shipped a bug where
    // relative-path worktrees weren't recognised; string-matching the raw file
    // content without resolving it is exactly how that happens.
    final wt = '${tmp.path}/rel';
    await git_(['worktree', 'add', '-q', wt, '-b', 'rel'], root);

    // Rewrite the gitfile by hand as a relative path, which is what an older or
    // differently-configured git produces.
    final gitFile = File('$wt/.git');
    gitFile.writeAsStringSync('gitdir: ../main/.git/worktrees/rel\n');

    final probe = probeLocalRepo(wt);

    expect(probe.kind, LocalRepoKind.linkedWorktree);
    expect(probe.worktree!.mainRepoPath, '${tmp.path}/main');
  });

  test('a SUBMODULE is not mistaken for a worktree', () async {
    // The trap: a submodule's `.git` is also a FILE, so "is .git a file" would
    // classify it as a worktree and we'd prompt for a main repo that does not
    // exist. It points into `.git/modules/`, not `.git/worktrees/`.
    final child = await initRepo('child');
    await git_([
      '-c',
      'protocol.file.allow=always',
      'submodule',
      'add',
      '-q',
      child,
      'sub',
    ], root);

    final probe = probeLocalRepo('$root/sub');

    expect(probe.kind, LocalRepoKind.submodule);
    expect(probe.worktree, isNull);
  });

  test('a folder that is not a repo at all', () {
    final plain = Directory('${tmp.path}/plain')..createSync();

    expect(probeLocalRepo(plain.path).kind, LocalRepoKind.unknown);
  });

  test('a --separate-git-dir repo is not a worktree', () async {
    // Its `.git` file points somewhere arbitrary, with no main repo to grant.
    final sep = '${tmp.path}/sep';
    final gitDir = '${tmp.path}/sep-gitdir';
    await Process.run('git', [
      'init',
      '-q',
      '--separate-git-dir',
      gitDir,
      sep,
    ], workingDirectory: tmp.path);

    final probe = probeLocalRepo(sep);

    expect(probe.kind, LocalRepoKind.unknown);
  });
}

Future<String> _canon(String path) => Directory(path).resolveSymbolicLinks();
