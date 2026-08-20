// The History filter field's query language: free text narrows by message,
// `key:value` terms narrow by author / file / SHA / date, and anything that
// merely LOOKS like a key (`fix:`, `feat:`) stays ordinary message text.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/history/log_filter.dart';

void main() {
  test('plain text is the message term', () {
    expect(
      parseLogFilter('fix the parser'),
      const LogFilter(message: 'fix the parser'),
    );
  });

  test('blank input narrows nothing', () {
    expect(parseLogFilter('   '), LogFilter.empty);
    expect(LogFilter.empty.isEmpty, isTrue);
  });

  test('each key fills its own field, and aliases agree', () {
    expect(
      parseLogFilter('author:mac file:lib/core/ after:2026-01-01'),
      const LogFilter(author: 'mac', path: 'lib/core/', since: '2026-01-01'),
    );
    // path:/since:/until:/commit: are the aliases of file:/after:/before:/sha:
    expect(
      parseLogFilter('path:lib since:yesterday until:today commit:abc123'),
      const LogFilter(
        path: 'lib',
        since: 'yesterday',
        until: 'today',
        sha: 'abc123',
      ),
    );
  });

  test('keys and free text combine, in any order', () {
    final filter = parseLogFilter('author:mac rename the field before:2026-07');
    expect(filter.author, 'mac');
    expect(filter.until, '2026-07');
    expect(filter.message, 'rename the field');
  });

  test('quoted values keep their spaces', () {
    expect(
      parseLogFilter('author:"Mac Smith" message text').author,
      'Mac Smith',
    );
    expect(parseLogFilter("author:'Mac Smith'").author, 'Mac Smith');
    expect(
      parseLogFilter('after:"2 weeks ago"'),
      const LogFilter(since: '2 weeks ago'),
    );
  });

  test('a conventional-commit prefix is text, not a filter key', () {
    // The whole point of the closed key set: `fix:` must search for the
    // literal subject text, never silently filter on an unknown `fix` key.
    expect(
      parseLogFilter('fix: history window'),
      const LogFilter(message: 'fix: history window'),
    );
    expect(
      parseLogFilter('feat(history): zoom').message,
      'feat(history): zoom',
    );
  });

  test('a key with no value yet narrows NOTHING — typing must not blank the '
      'list', () {
    // The old grammar demoted a trailing `author:` to message text — but a
    // message search for the literal word "author:" blanks the list just as
    // surely as an empty author filter would. Dropping the token is the only
    // reading that actually holds the list still mid-typing.
    expect(parseLogFilter('author:'), LogFilter.empty);
    expect(parseLogFilter('fix author:'), const LogFilter(message: 'fix'));
  });

  test('a space after the colon binds the next token as the value', () {
    // `author: samuel` is how the phrase is written in prose, and it is what
    // users actually type. The old grammar silently demoted BOTH tokens to
    // message text, so the search looked applied and found nothing — the
    // original "history search is completely broken" report.
    expect(parseLogFilter('author: samuel'), const LogFilter(author: 'samuel'));
    expect(parseLogFilter('sha: 14791'), const LogFilter(sha: '14791'));
    expect(
      parseLogFilter('author: "Mac Smith"'),
      const LogFilter(author: 'Mac Smith'),
    );
    expect(
      parseLogFilter('rename author: mac after: 2026-01-01'),
      const LogFilter(message: 'rename', author: 'mac', since: '2026-01-01'),
    );
    // …but never at the cost of eating a real term: a recognized key:value
    // following a valueless key stays a term, and the dangling key is dropped.
    expect(parseLogFilter('author: file:lib'), const LogFilter(path: 'lib'));
  });

  test('a repeated key keeps the last value', () {
    expect(parseLogFilter('author:mac author:sam').author, 'sam');
  });

  test('keys are case-insensitive; values are preserved verbatim', () {
    expect(parseLogFilter('Author:Mac').author, 'Mac');
  });

  test('sha: is parsed as a term — resolving it is git\'s job', () {
    // It used to be filtered out of the already-fetched rows here; it is now a
    // `git log` criterion like every other term, so a hash is found wherever it
    // lives. What that resolution means is covered in log_search_test.dart.
    expect(parseLogFilter('sha:A90916F').sha, 'A90916F');
    expect(parseLogFilter('commit:a90916f').sha, 'a90916f');
  });
}
