// Unit tests for the parseGitLog fix (H5/M3): commit subjects containing
// the field separator byte (0x1F) must not truncate the subject, and those
// containing the record separator byte (0x1E) must not fragment the record
// stream and hide adjacent commits.
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  group('parseGitLog — separator injection resilience', () {
    // The wire format: fields joined by \x1F, records joined by \x1E.
    // Fields: hash, shortHash, authorName, authorEmail, date, parents, subject
    // Hashes must be at least 7 chars so shortHash = hash.substring(0, 7)
    // is well-defined (full OIDs are 40 hex chars on the wire).
    String record(
      String hash,
      String subject, {
      String parents = '',
    }) {
      assert(hash.length >= 7, 'test hash must be ≥7 chars');
      return [
        hash,
        hash.substring(0, 7),
        'Test Author',
        'test@test.com',
        '2024-01-01T00:00:00+00:00',
        parents,
        subject,
      ].join(GitService.fieldSep);
    }

    test('normal subjects parse correctly', () {
      final raw = record('aaaaaaaa', 'fix: normal commit');
      final commits = parseGitLog(raw);
      expect(commits.length, 1);
      expect(commits.first.subject, 'fix: normal commit');
      expect(commits.first.hash, 'aaaaaaaa');
    });

    test('subject containing fieldSep (0x1F) is not truncated (M3)', () {
      // A subject that contains the unit separator byte — split() would
      // produce 8 fields, and f[6] would only capture the prefix.
      final subjectWithSep = 'part1${GitService.fieldSep}part2';
      final raw = record('bbbbbbbb', subjectWithSep);
      final commits = parseGitLog(raw);
      expect(commits.length, 1);
      // The subject must be fully recovered by rejoining from index 6 onward.
      // _stripSeps then removes the embedded separator bytes.
      expect(commits.first.subject, 'part1part2');
    });

    test('subject with multiple fieldSep bytes recovers full text', () {
      final sep = GitService.fieldSep;
      final subjectWithMultipleSeps = 'a${sep}b${sep}c${sep}d';
      final raw = record('cccccccc', subjectWithMultipleSeps);
      final commits = parseGitLog(raw);
      expect(commits.length, 1);
      // _stripSeps strips the separator bytes, so we get 'abcd'.
      expect(commits.first.subject, 'abcd');
    });

    test('recordSep in subject does not hide adjacent commits (H5)', () {
      // Two normal commits followed by one with a recordSep in its subject.
      // The injected recordSep will split the record stream, but the fragment
      // should be < 7 fields and thus skipped, while the other records remain.
      final normalA = record('aaaaaaaa', 'commit A');
      final normalB = record('bbbbbbbb', 'commit B');
      final raw = '$normalA${GitService.recordSep}$normalB';
      final commits = parseGitLog(raw);
      // Both commits should parse successfully.
      expect(commits.length, 2);
      expect(commits[0].hash, 'aaaaaaaa');
      expect(commits[1].hash, 'bbbbbbbb');
    });

    test('multiple records with parents parse correctly', () {
      final merge = record(
        'mmmmmmmm',
        'merge feature',
        parents: 'aaaaaaaa bbbbbbbb',
      );
      final a = record('aaaaaaaa', 'feat A');
      final b = record('bbbbbbbb', 'feat B');
      final raw =
          '$merge${GitService.recordSep}$a${GitService.recordSep}$b';
      final commits = parseGitLog(raw);
      expect(commits.length, 3);
      expect(commits[0].parents, ['aaaaaaaa', 'bbbbbbbb']);
      expect(commits[1].parents, isEmpty);
      expect(commits[2].parents, isEmpty);
    });

    test('empty input yields empty list', () {
      expect(parseGitLog(''), isEmpty);
      expect(parseGitLog('   '), isEmpty);
      expect(parseGitLog('\n'), isEmpty);
    });

    test('truncated records (< 7 fields) are silently skipped', () {
      final good = record('aaaaaaaa', 'good commit');
      const truncated = 'hash${GitService.fieldSep}short'; // only 2 fields
      final raw =
          '$good${GitService.recordSep}$truncated';
      final commits = parseGitLog(raw);
      expect(commits.length, 1);
      expect(commits.first.hash, 'aaaaaaaa');
    });
  });
}
