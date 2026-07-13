// The History filter, end to end: what the user types, run against a real
// repository by a real `git log`.
//
// These are deliberately not argv assertions. Every bug they cover was a case
// where the argv looked perfectly reasonable and git's answer was still empty —
// a rooted pathspec, a case-sensitive `--author`, a regex where a search term
// was meant. Only running git can tell those apart, so the fixture below is a
// real repo and the assertions are on the commits that come back.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/log_search.dart';

void main() {
  group('term compilation', () {
    test('a term is literal text, not a regex', () {
      // The metacharacters that made git exit 128 mid-search.
      expect(globToRegExp('[WIP]'), r'\[WIP\]');
      expect(globToRegExp('feat(core)'), r'feat\(core\)');
      expect(globToRegExp(r'a\'), r'a\\');
      expect(globToRegExp('c++'), r'c\+\+');
    });

    test('* and ? are the wildcards', () {
      expect(globToRegExp('hist*view'), 'hist.*view');
      expect(globToRegExp('v?.dart'), r'v.\.dart');
      // The escaping still applies around them.
      expect(globToRegExp('fix(*)'), r'fix\(.*\)');
    });

    test('message words are separate patterns — to be ANDed, not concatenated', () {
      expect(messageGrepPatterns('patch collapse'), ['patch', 'collapse']);
      expect(messageGrepPatterns('  spaced   out  '), ['spaced', 'out']);
      expect(messageGrepPatterns(''), isEmpty);
      expect(messageGrepPatterns(null), isEmpty);
    });

    test('an author is one pattern — its spaces belong to the name', () {
      expect(authorGrepPattern('Mac Smith'), 'Mac Smith');
      expect(authorGrepPattern('  '), isNull);
      expect(authorGrepPattern(null), isNull);
    });

    test('a path term is read every way it could reasonably be meant', () {
      // Bare term: the rooted reading, plus filename- and folder-substring at
      // any depth.
      expect(searchPathspecs('history'), [
        ':(icase)history',
        ':(icase,glob)**/*history*',
        ':(icase,glob)**/*history*/**',
      ]);
      // A trailing slash means "this folder"; it must not leak into the
      // substring forms.
      expect(
        searchPathspecs('lib/core/'),
        contains(':(icase,glob)**/*lib/core*'),
      );
      // A user's own glob is taken at its word, just not root-anchored.
      expect(searchPathspecs('*.dart'), [
        ':(icase,glob)*.dart',
        ':(icase,glob)**/*.dart',
      ]);
      expect(searchPathspecs(''), isEmpty);
      expect(searchPathspecs(null), isEmpty);
    });

    test('only a real hash prefix is worth a round trip', () {
      expect(isResolvableShaPrefix('a90916f'), isTrue);
      expect(isResolvableShaPrefix('A90916F'), isTrue);
      // Git's own object-name disambiguation needs 4 hex digits.
      expect(isResolvableShaPrefix('a90'), isFalse);
      expect(isResolvableShaPrefix('zzzz'), isFalse);
      expect(isResolvableShaPrefix(''), isFalse);
      expect(isResolvableShaPrefix(null), isFalse);
    });
  });

  group('against a real repository', () {
    late Directory repo;
    late GitService git;
    // Hashes of the fixture commits, by the tag we give them below.
    late Map<String, String> sha;

    Future<void> run(List<String> args) async {
      final r = await Process.run(args.first, args.skip(1).toList(),
          workingDirectory: repo.path);
      if (r.exitCode != 0) {
        throw StateError('fixture setup failed: ${args.join(' ')}\n${r.stderr}');
      }
    }

    /// Commits [file] with [subject], attributed to [author].
    Future<void> commit({
      required String file,
      required String subject,
      required String author,
    }) async {
      final f = File('${repo.path}/$file');
      await f.parent.create(recursive: true);
      await f.writeAsString('${f.path}\n${DateTime.now().microsecondsSinceEpoch}');
      await run(['git', 'add', '--all']);
      await run([
        'git',
        '-c', 'user.name=Fixture',
        '-c', 'user.email=fixture@example.com',
        'commit',
        '--author=$author',
        '-m', subject,
      ]);
    }

    Future<String> head() async {
      final r = await Process.run('git', ['rev-parse', 'HEAD'],
          workingDirectory: repo.path);
      return (r.stdout as String).trim();
    }

    setUpAll(() async {
      repo = Directory.systemTemp.createTempSync('log_search_test_');
      git = GitService(LocalCommandExecutor());
      sha = {};

      await run(['git', 'init', '-b', 'main']);

      await commit(
        file: 'lib/core/alpha.dart',
        subject: 'feat(core): add alpha',
        author: 'Mac Smith <mac@example.com>',
      );
      sha['alpha'] = await head();

      await commit(
        file: 'lib/features/history/history_view.dart',
        subject: 'feat(history): add collapse to gap rows',
        author: 'Ada Lovelace <ada@example.com>',
      );
      sha['history'] = await head();

      await commit(
        file: 'README.md',
        subject: '[WIP] fix (again)',
        author: 'Mac Smith <mac@example.com>',
      );
      sha['wip'] = await head();

      // A commit HEAD cannot reach. `sha:` must still find it — that is the
      // whole difference between resolving a hash and filtering loaded rows.
      await run(['git', 'checkout', '-q', '-b', 'side']);
      await commit(
        file: 'docs/deep.txt',
        subject: 'side branch work',
        author: 'Ada Lovelace <ada@example.com>',
      );
      sha['side'] = await head();
      await run(['git', 'checkout', '-q', 'main']);
    });

    tearDownAll(() => repo.deleteSync(recursive: true));

    Future<List<String>> subjects({
      String? grep,
      String? author,
      String? pathQuery,
      String? shaTerm,
      bool all = false,
    }) async {
      final commits = await git.log(
        repo.path,
        grep: grep,
        author: author,
        pathQuery: pathQuery,
        sha: shaTerm,
        all: all,
      );
      return [for (final c in commits) c.subject];
    }

    test('author: matches case-insensitively', () async {
      // The bug: `-i` was only passed alongside `--grep`, so an author term on
      // its own was case-sensitive and `author:mac` found nothing at all.
      expect(await subjects(author: 'mac'), hasLength(2));
      expect(await subjects(author: 'MAC SMITH'), hasLength(2));
      expect(await subjects(author: 'ada@example.com'), hasLength(1));
    });

    test('author: takes wildcards', () async {
      expect(await subjects(author: 'ada*example.com'), hasLength(1));
    });

    test('every word of a message search must match, in any order', () async {
      // The bug: the words were joined into a single pattern, which only ever
      // matched the contiguous phrase — so a commit containing both words was
      // not found.
      expect(
        await subjects(grep: 'add collapse'),
        ['feat(history): add collapse to gap rows'],
      );
      expect(
        await subjects(grep: 'collapse add'),
        ['feat(history): add collapse to gap rows'],
      );
      // …and a word that matches nothing still excludes the commit.
      expect(await subjects(grep: 'add collapse nonesuch'), isEmpty);
    });

    test('a message search takes wildcards', () async {
      expect(await subjects(grep: 'coll*rows'), hasLength(1));
      expect(await subjects(grep: 'feat*core'), hasLength(1));
    });

    test('regex metacharacters are searched for, not executed', () async {
      // The bug: these are regex syntax. `[WIP]` is an unbalanced-bracket
      // error, which git reports by exiting 128 — surfacing not as "no
      // results" but as the entire History list failing to load.
      expect(await subjects(grep: '[WIP]'), ['[WIP] fix (again)']);
      expect(await subjects(grep: 'fix (again)'), ['[WIP] fix (again)']);
      expect(await subjects(grep: r'a\'), isEmpty);
    });

    test('file: finds a bare filename, at any depth', () async {
      // The bug: a pathspec is rooted at the repo root, so the bare filename a
      // user actually types matched nothing.
      expect(
        await subjects(pathQuery: 'history_view.dart'),
        ['feat(history): add collapse to gap rows'],
      );
    });

    test('file: finds a bare folder name, at any depth', () async {
      expect(
        await subjects(pathQuery: 'history'),
        ['feat(history): add collapse to gap rows'],
      );
    });

    test('file: matches a substring of a path', () async {
      expect(await subjects(pathQuery: 'alpha'), hasLength(1));
    });

    test('file: still honours a full rooted path', () async {
      expect(await subjects(pathQuery: 'lib/core/'), hasLength(1));
      expect(
        await subjects(pathQuery: 'lib/features/history/history_view.dart'),
        hasLength(1),
      );
    });

    test('file: is case-insensitive', () async {
      expect(await subjects(pathQuery: 'LIB/CORE/'), hasLength(1));
      expect(await subjects(pathQuery: 'HISTORY_VIEW.DART'), hasLength(1));
    });

    test('file: takes wildcards', () async {
      expect(await subjects(pathQuery: '*.dart'), hasLength(2));
      expect(await subjects(pathQuery: '*.md'), hasLength(1));
    });

    test('file: matching nothing is empty, not everything', () async {
      expect(await subjects(pathQuery: 'nosuchfile.xyz'), isEmpty);
    });

    test('sha: finds a commit HEAD cannot reach', () async {
      // The bug: `sha:` filtered the rows already fetched — which are HEAD's,
      // to the current page depth — so a hash on any other branch, or simply
      // further back than the page, was invisible.
      final prefix = sha['side']!.substring(0, 8);
      expect(await subjects(shaTerm: prefix), ['side branch work']);
      // …without needing the all-branches toggle.
      expect(await subjects(shaTerm: prefix, all: false), hasLength(1));
    });

    test('sha: accepts a full hash and any prefix, in any case', () async {
      expect(await subjects(shaTerm: sha['alpha']!), ['feat(core): add alpha']);
      expect(
        await subjects(shaTerm: sha['alpha']!.substring(0, 7)),
        ['feat(core): add alpha'],
      );
      expect(
        await subjects(shaTerm: sha['alpha']!.substring(0, 7).toUpperCase()),
        ['feat(core): add alpha'],
      );
    });

    test('sha: matching nothing is empty — never an unfiltered log', () async {
      // Every one of these is "no such commit". Returning the full history for
      // any of them would be a filter that silently does nothing.
      expect(await subjects(shaTerm: 'deadbeef'), isEmpty);
      expect(await subjects(shaTerm: 'zzzz'), isEmpty);
      expect(await subjects(shaTerm: 'a90'), isEmpty);
    });

    test('sha: narrows with the other terms rather than overriding them',
        () async {
      final prefix = sha['alpha']!.substring(0, 8);
      expect(await subjects(shaTerm: prefix, author: 'mac'), hasLength(1));
      // Same commit, an author it isn't by: the terms are ANDed.
      expect(await subjects(shaTerm: prefix, author: 'ada'), isEmpty);
    });

    test('terms combine as AND', () async {
      expect(await subjects(grep: 'feat', author: 'mac'), hasLength(1));
      expect(await subjects(grep: 'feat', author: 'ada'), hasLength(1));
      expect(
        await subjects(pathQuery: '*.dart', author: 'mac'),
        ['feat(core): add alpha'],
      );
      // The subtle one: `--all-match` governs the message words, and an author
      // still has to match on top of it — it must not widen into an OR.
      expect(
        await subjects(grep: 'add collapse', author: 'ada'),
        ['feat(history): add collapse to gap rows'],
      );
      expect(await subjects(grep: 'add collapse', author: 'mac'), isEmpty);
    });

    test('an exact path still drives file history — `--follow` is intact',
        () async {
      // `path` (exact, one pathspec) and `pathQuery` (a user's search term,
      // several pathspecs) are different languages; `--follow` accepts only the
      // former, and git rejects it outright with more than one pathspec.
      final commits = await git.log(
        repo.path,
        path: 'lib/core/alpha.dart',
        follow: true,
      );
      expect(commits.map((c) => c.subject), ['feat(core): add alpha']);
    });

    test('no terms is the plain history', () async {
      expect(await subjects(), hasLength(3));
      expect(await subjects(all: true), hasLength(4));
    });
  });
}
