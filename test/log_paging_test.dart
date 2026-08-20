// Paging the History panel with `--skip` is only sound if git's walk is stable:
// page two must be the exact continuation of page one, not a differently-ordered
// re-walk. That is a claim about *git*, and a fake git would simply agree with
// whatever this code already believes — so it is checked against a real
// repository, including the case the fixture is built for: `--topo-order` over
// branchy history, where date order and ancestry disagree.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory repo;
  late GitService git;

  Future<void> run(List<String> args) async {
    final r = await Process.run(
      args.first,
      args.skip(1).toList(),
      workingDirectory: repo.path,
    );
    if (r.exitCode != 0) {
      throw StateError('fixture setup failed: ${args.join(' ')}\n${r.stderr}');
    }
  }

  Future<void> commit(String subject, {String file = 'main.txt'}) async {
    await File('${repo.path}/$file').writeAsString(subject);
    await run(['git', 'add', '--all']);
    await run([
      'git',
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.com',
      'commit',
      '-m',
      subject,
    ]);
  }

  setUpAll(() async {
    repo = Directory.systemTemp.createTempSync('log_paging_test_');
    git = GitService(LocalCommandExecutor());
    await run(['git', 'init', '-b', 'main']);
    for (var i = 0; i < 12; i++) {
      await commit('c$i');
    }
    // A merge, so the walk is genuinely branchy: `--topo-order` then has real
    // work to do, and a naive "skip N" into a re-run walk has something to get
    // wrong. Branch off c5, add two commits, merge back.
    await run(['git', 'checkout', '-b', 'side', 'HEAD~6']);
    await commit('s0', file: 'side.txt');
    await commit('s1', file: 'side.txt');
    await run(['git', 'checkout', 'main']);
    await run([
      'git',
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.com',
      'merge',
      '--no-ff',
      'side',
      '-m',
      'merge side',
    ]);
  });

  tearDownAll(() => repo.deleteSync(recursive: true));

  test(
    'pages stitch into exactly the walk one deep log would have produced',
    () async {
      // The invariant the whole paging design rests on. If this ever fails,
      // History is showing a list git never actually produced.
      final whole = await git.log(repo.path, maxCount: 100);
      expect(
        whole.length,
        greaterThan(12),
        reason: 'sanity: the fixture is deep',
      );

      const pageSize = 4;
      final paged = <GitCommit>[];
      for (var skip = 0; skip < whole.length; skip += pageSize) {
        final page = await git.log(repo.path, maxCount: pageSize, skip: skip);
        paged.addAll(page);
      }

      expect(
        [for (final c in paged) c.hash],
        [for (final c in whole) c.hash],
        reason:
            'a stitched sequence of --skip pages must equal the single walk, '
            'in the same topological order',
      );
    },
  );

  test('a page past the end is empty, not an error', () async {
    // How the panel learns the history ran out: a short page, not a failure.
    final page = await git.log(repo.path, maxCount: 10, skip: 10000);
    expect(page, isEmpty);
  });

  test(
    'skip composes with a filter — it offsets the MATCHES, not the walk',
    () async {
      // Paging a filtered History (`author:`, `sha:`, a path…) skips within the
      // filtered result. If --skip counted raw commits instead, page two of a
      // search would silently drop matches.
      final all = await git.log(repo.path, maxCount: 100, grep: 'c');
      expect(all.length, greaterThan(4));

      final second = await git.log(repo.path, maxCount: 2, skip: 2, grep: 'c');
      expect(
        [for (final c in second) c.hash],
        [for (final c in all.skip(2).take(2)) c.hash],
      );
    },
  );
}
