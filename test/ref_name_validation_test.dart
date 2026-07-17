// The shared check-ref-format approximation — one rule set for branch AND
// tag names (they share git's ref-format constraints; only wording differs).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/ref_name_validation.dart';

void main() {
  test('acceptable names pass', () {
    for (final name in [
      'main',
      'feature/add-thing',
      'v1.2.3',
      'hotfix-2026.07',
      'üñïçødé',
      'a@b', // @ is fine when not "@" alone or "@{"
    ]) {
      expect(refNameProblem(name), isNull, reason: name);
      expect(refNameProblem(name, kind: 'tag'), isNull, reason: name);
    }
  });

  test('empty is silently acceptable (button-disable, not an error)', () {
    expect(refNameProblem(''), isNull);
  });

  test('rejections name the specific violation', () {
    expect(refNameProblem('has space'), contains('space'));
    expect(refNameProblem('a..b'), contains('".."'));
    expect(refNameProblem('a@{b'), contains('@{'));
    expect(refNameProblem('@'), contains('"@"'));
    expect(refNameProblem('-lead'), contains('start with "-"'));
    expect(refNameProblem('/lead'), contains('"/"'));
    expect(refNameProblem('trail/'), contains('"/"'));
    expect(refNameProblem('a//b'), contains('"//"'));
    expect(refNameProblem('.lead'), contains('"."'));
    expect(refNameProblem('trail.'), contains('"."'));
    expect(refNameProblem('a\tb'), isNotNull);
    for (final ch in ['~', '^', ':', '?', '*', '[', r'\']) {
      expect(refNameProblem('a${ch}b'), contains(ch), reason: ch);
    }
  });

  test('component-level rules: dot-led and .lock-suffixed components', () {
    expect(refNameProblem('a/.hidden'), contains('component'));
    expect(refNameProblem('a/b.lock'), contains('.lock'));
    expect(refNameProblem('a.lock/b'), contains('.lock'));
    expect(refNameProblem('feature/ok.dots'), isNull);
  });

  test('kind only changes wording', () {
    expect(refNameProblem('a..b'), startsWith('A branch name'));
    expect(refNameProblem('a..b', kind: 'tag'), startsWith('A tag name'));
  });
}
