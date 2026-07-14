// End-to-end History search against real git in a scratch repo — the same
// honest-test rationale as worktree_commands_test.dart: log_search_test.dart
// proves the pattern COMPILERS produce the strings we intend, but only a real
// `git log` can prove those strings mean what we think in git's dialect
// (`--extended-regexp`, `--all-match`, `:(icase,glob)` pathspec magic,
// `--no-walk` over `--disambiguate` output). A flag misunderstanding shows up
// here as a wrong result set, not as a green unit test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tempDir;
  late String repo;
  late GitService git;

  Future<String> raw(List<String> args, {String? cwd}) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: cwd ?? repo,
    );
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  Future<void> commitFile(
    String path,
    String content,
    String message, {
    String? author,
  }) async {
    final file = File('$repo/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    await raw(['add', '--all']);
    await raw([
      'commit',
      '-q',
      '-m',
      message,
      if (author != null) '--author=$author',
    ]);
  }

  List<String> subjects(List<GitCommit> commits) =>
      [for (final c in commits) c.subject];

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('log_search_int_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    git = GitService(LocalCommandExecutor());

    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Mac Smith']);
    await raw(['config', 'user.email', 'mac@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);

    await commitFile(
      'lib/core/history_view.dart',
      'a\n',
      'feat(history): add HistoryView pane',
    );
    await commitFile(
      'lib/core/patch_model.dart',
      'b\n',
      'fix [WIP] patch collapse regression',
      author: 'Other Dev <other@example.com>',
    );
    await commitFile('docs/guide.md', 'c\n', 'docs: write user guide');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('message search', () {
    test('multi-word means AND across words, not a contiguous phrase',
        () async {
      final hits = await git.log(repo, grep: 'patch collapse');
      expect(subjects(hits), ['fix [WIP] patch collapse regression']);

      // The words never appear adjacent in that order — AND still finds it.
      final reversed = await git.log(repo, grep: 'collapse patch');
      expect(subjects(reversed), ['fix [WIP] patch collapse regression']);
    });

    test('regex metacharacters match literally instead of exit-128', () async {
      final hits = await git.log(repo, grep: '[WIP]');
      expect(subjects(hits), ['fix [WIP] patch collapse regression']);
    });

    test('* is a glob wildcard and matching is case-insensitive', () async {
      final hits = await git.log(repo, grep: 'feat*PANE');
      expect(subjects(hits), ['feat(history): add HistoryView pane']);
    });

    test('a term matching nothing yields empty, not everything', () async {
      expect(await git.log(repo, grep: 'zzz-no-such'), isEmpty);
    });
  });

  group('author search', () {
    test('matches part of a name case-insensitively', () async {
      final hits = await git.log(repo, author: 'other');
      expect(subjects(hits), ['fix [WIP] patch collapse regression']);
    });

    test('author and message narrow together (AND)', () async {
      expect(
        await git.log(repo, grep: 'patch', author: 'other'),
        hasLength(1),
      );
      expect(
        await git.log(repo, grep: 'history', author: 'other'),
        isEmpty,
        reason: 'the history commit is by Mac, not Other',
      );
    });
  });

  group('path search (pathQuery)', () {
    test('a bare filename matches at any depth, case-insensitively',
        () async {
      final hits = await git.log(repo, pathQuery: 'History_View.dart');
      expect(subjects(hits), ['feat(history): add HistoryView pane']);
    });

    test('a bare folder name matches everything under it', () async {
      final hits = await git.log(repo, pathQuery: 'core');
      expect(hits, hasLength(2));
    });

    test('a user glob is honored at any depth', () async {
      final hits = await git.log(repo, pathQuery: '*.dart');
      expect(hits, hasLength(2));
      expect(subjects(await git.log(repo, pathQuery: '*.md')), [
        'docs: write user guide',
      ]);
    });
  });

  group('sha search', () {
    test('a full hash finds its commit; a 4-char prefix finds it too',
        () async {
      final full = await raw(['rev-parse', 'HEAD']);
      expect(
        subjects(await git.log(repo, sha: full)),
        ['docs: write user guide'],
      );
      expect(
        subjects(await git.log(repo, sha: full.substring(0, 4))),
        contains('docs: write user guide'),
      );
    });

    test('finds a commit deeper than the page size (object-db, not walk)',
        () async {
      final oldest = await raw(['rev-list', '--max-parents=0', 'HEAD']);
      final hits = await git.log(repo, sha: oldest, maxCount: 1);
      expect(subjects(hits), ['feat(history): add HistoryView pane']);
    });

    test('finds a commit reachable only from another branch', () async {
      await raw(['checkout', '-q', '-b', 'side']);
      await commitFile('side.txt', 's\n', 'side: only on the side branch');
      final sideSha = await raw(['rev-parse', 'HEAD']);
      await raw(['checkout', '-q', 'main']);

      final hits = await git.log(repo, sha: sideSha);
      expect(subjects(hits), ['side: only on the side branch']);
    });

    test('an unresolvable prefix is "no results", not an error or a full log',
        () async {
      expect(await git.log(repo, sha: 'deadbeef'), isEmpty);
      expect(await git.log(repo, sha: 'zzzz'), isEmpty);
      expect(await git.log(repo, sha: 'ab'), isEmpty, reason: 'too short');
    });

    test('survives a prefix that also names blobs and trees', () async {
      // `rev-parse --disambiguate` returns EVERY object type; `--no-walk` must
      // shrug off the non-commits rather than fail the whole search. Find a
      // prefix that provably matches at least one non-commit object.
      final blob = await raw(['rev-parse', 'HEAD:docs/guide.md']);
      final hits = await git.log(repo, sha: blob.substring(0, 4));
      // No throw is the point; the result may or may not contain commits.
      expect(hits, isA<List<GitCommit>>());
    });
  });

  group('date filters', () {
    test('since/until pass through to git verbatim', () async {
      expect(await git.log(repo, since: '1 minute ago'), hasLength(3));
      expect(await git.log(repo, until: '1990-01-01'), isEmpty);
      expect(await git.log(repo, since: '2030-01-01'), isEmpty);
    });

    test('git COERCES a bad date rather than rejecting it — the quirk '
        'dateTermProblem exists to flag', () async {
      // Verified against git 2.55: a year past 2099 is silently read as the
      // CURRENT year, so `since:2990-01-01` behaves like `since:<this Jan>`
      // and filters nothing (every commit here is newer). If a future git
      // starts rejecting these instead, this test failing is the signal that
      // the client-side warning can be retired.
      expect(await git.log(repo, since: '2990-01-01'), hasLength(3));
      // Unparseable text is read as "now", so `until:` filters nothing.
      // (The `since:` twin — "nothing but this instant" — isn't asserted
      // here: the fixture commits are created the same second the query
      // runs, so they race the boundary.)
      expect(await git.log(repo, until: 'garbage-text'), hasLength(3));
    });
  });

  group('scope and combination', () {
    test('all-branches search finds side-branch commits', () async {
      await raw(['checkout', '-q', '-b', 'topic']);
      await commitFile('t.txt', 't\n', 'topic: special marker xyzzy');
      await raw(['checkout', '-q', 'main']);

      expect(await git.log(repo, grep: 'xyzzy'), isEmpty);
      expect(
        subjects(await git.log(repo, grep: 'xyzzy', all: true)),
        ['topic: special marker xyzzy'],
      );
    });

    test('noMerges drops merge commits from a search', () async {
      await raw(['checkout', '-q', '-b', 'feature']);
      await commitFile('f.txt', 'f\n', 'feature work');
      await raw(['checkout', '-q', 'main']);
      await raw(['merge', '--no-ff', '-q', '-m', 'merge feature work', 'feature']);

      expect(await git.log(repo, grep: 'feature work'), hasLength(2));
      expect(
        subjects(await git.log(repo, grep: 'feature work', noMerges: true)),
        ['feature work'],
      );
    });

    test('message + path + author together', () async {
      final hits = await git.log(
        repo,
        grep: 'patch',
        pathQuery: 'lib',
        author: 'other',
      );
      expect(subjects(hits), ['fix [WIP] patch collapse regression']);
    });
  });

  group('paging under a filter', () {
    test('--skip pages through filtered results without overlap', () async {
      for (var i = 0; i < 5; i++) {
        await commitFile('bulk.txt', '$i\n', 'bulk commit $i');
      }
      final page1 = await git.log(repo, grep: 'bulk', maxCount: 2);
      final page2 = await git.log(repo, grep: 'bulk', maxCount: 2, skip: 2);
      final page3 = await git.log(repo, grep: 'bulk', maxCount: 2, skip: 4);

      final all = [...page1, ...page2, ...page3];
      expect(all, hasLength(5));
      expect({for (final c in all) c.hash}, hasLength(5), reason: 'no overlap');
    });
  });
}
