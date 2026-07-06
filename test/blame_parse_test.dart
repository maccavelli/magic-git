// Unit test for the `git blame --line-porcelain` parser.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  test('parseBlame extracts commit, author, date, line number, content', () {
    const raw =
        '0123456789012345678901234567890123456789 1 1 1\n'
        'author Jane Dev\n'
        'author-mail <jane@example.com>\n'
        'author-time 1700000000\n'
        'author-tz +0000\n'
        'summary initial import\n'
        'filename a.txt\n'
        '\tfirst line\n'
        '0123456789012345678901234567890123456789 2 2\n'
        'author Jane Dev\n'
        'author-time 1700000000\n'
        'summary initial import\n'
        '\tsecond line\n';

    final lines = parseBlame(raw);
    expect(lines.length, 2);

    expect(lines[0].hash, '0123456789012345678901234567890123456789');
    expect(lines[0].author, 'Jane Dev');
    expect(lines[0].summary, 'initial import');
    expect(lines[0].lineNumber, 1);
    expect(lines[0].content, 'first line');
    // 1700000000s since epoch → 2023-11-14 (UTC).
    expect(lines[0].date, '2023-11-14');

    expect(lines[1].lineNumber, 2);
    expect(lines[1].content, 'second line');
  });

  test('parseBlame handles SHA-256 (64-hex) object ids', () {
    final sha256 = 'a' * 64;
    final raw =
        '$sha256 1 1 1\n'
        'author Jane Dev\n'
        'author-time 1700000000\n'
        'summary sha256 repo\n'
        '\tonly line\n';

    final lines = parseBlame(raw);
    // Pre-fix the 40-hex-only header regex matched nothing here, so every line
    // came back with an empty hash and line number 0.
    expect(lines.length, 1);
    expect(lines.single.hash, sha256);
    expect(lines.single.lineNumber, 1);
    expect(lines.single.content, 'only line');
  });
}
