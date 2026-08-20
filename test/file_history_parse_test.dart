// parseFileHistory: the interleave of the log wire format with --name-status
// records. The shape (verified against real git): each commit emits its
// fieldSep-joined fields, then recordSep, then a blank line and one status
// line — so after splitting on recordSep, a chunk's status line belongs to the
// PREVIOUS commit and its fields line opens the next one.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

const _fs = GitService.fieldSep;
const _rs = GitService.recordSep;

String _fields(String hash, String subject) => [
  hash * 40,
  hash * 7,
  'Dev',
  'd@e',
  '2026-07-04T10:00:00+00:00',
  '',
  subject,
].join(_fs);

void main() {
  test('carries each commit\'s own path across a rename', () {
    final raw =
        '${_fields('a', 'edit new')}$_rs\n\nM\tnew_name.txt\n'
        '${_fields('b', 'rename')}$_rs\n\nR100\told_name.txt\tnew_name.txt\n'
        '${_fields('c', 'add old')}$_rs\n\nA\told_name.txt\n';

    final entries = parseFileHistory(raw);
    expect(
      [for (final e in entries) e.commit.subject],
      ['edit new', 'rename', 'add old'],
    );
    expect(
      [for (final e in entries) e.pathAtCommit],
      ['new_name.txt', 'new_name.txt', 'old_name.txt'],
      reason: 'an R record\'s path at that commit is its NEW side',
    );
  });

  test('unquotes a C-quoted path', () {
    final raw =
        '${_fields('a', 'tricky')}$_rs\n\nM\t"with\\ttab \\"q\\" \\303\\251.txt"\n';
    final entries = parseFileHistory(raw);
    expect(entries.single.pathAtCommit, 'with\ttab "q" é.txt');
  });

  test('a truncated record is skipped; a missing status line leaves the path '
      'null (caller falls back to the queried path)', () {
    const truncated = 'only${_fs}two$_rs\n\nM\tx.txt\n';
    expect(parseFileHistory(truncated), isEmpty);

    final noStatus = '${_fields('a', 'bare')}$_rs';
    final entries = parseFileHistory(noStatus);
    expect(entries.single.commit.subject, 'bare');
    expect(entries.single.pathAtCommit, isNull);
  });
}
