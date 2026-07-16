import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/intraline_diff.dart';

/// Reconstructs the changed substrings for readable assertions.
List<String> slices(String line, List<IntralineRange> ranges) =>
    [for (final r in ranges) line.substring(r.start, r.end)];

void main() {
  group('computeIntralineDiff', () {
    test('identical lines have no changes', () {
      expect(computeIntralineDiff('same', 'same').isEmpty, isTrue);
    });

    test('a single changed word is isolated on both sides', () {
      const oldLine = 'final value = compute(a, b);';
      const newLine = 'final value = compute(a, c);';
      final d = computeIntralineDiff(oldLine, newLine);
      expect(slices(oldLine, d.oldRanges), ['b']);
      expect(slices(newLine, d.newRanges), ['c']);
    });

    test('insertion only marks the new side', () {
      final d = computeIntralineDiff('foo(a)', 'foo(a, b)');
      expect(d.oldRanges, isEmpty);
      // The added ", b" is the changed run on the new side.
      expect(slices('foo(a, b)', d.newRanges).join(), contains('b'));
    });

    test('deletion only marks the old side', () {
      final d = computeIntralineDiff('foo(a, b)', 'foo(a)');
      expect(d.newRanges, isEmpty);
      expect(slices('foo(a, b)', d.oldRanges).join(), contains('b'));
    });

    test('empty old line marks the whole new line', () {
      final d = computeIntralineDiff('', 'added');
      expect(d.oldRanges, isEmpty);
      expect(d.newRanges, [const IntralineRange(0, 5)]);
    });

    test('empty new line marks the whole old line', () {
      final d = computeIntralineDiff('removed', '');
      expect(d.newRanges, isEmpty);
      expect(d.oldRanges, [const IntralineRange(0, 7)]);
    });

    test('does not fragment inside a changed identifier', () {
      // "oldName" -> "newName": the differing word is one contiguous range,
      // not per-character noise. The shared "Name" suffix is a separate word
      // token, so only the leading word differs.
      const a = 'x.oldName = 1;';
      const b = 'x.newName = 1;';
      final d = computeIntralineDiff(a, b);
      expect(slices(a, d.oldRanges), ['oldName']);
      expect(slices(b, d.newRanges), ['newName']);
    });

    test('multiple disjoint changes yield multiple ranges', () {
      const a = 'a b c d';
      const b = 'a X c Y';
      final d = computeIntralineDiff(a, b);
      expect(slices(a, d.oldRanges), ['b', 'd']);
      expect(slices(b, d.newRanges), ['X', 'Y']);
    });

    test('ranges are ordered and non-overlapping', () {
      const a = 'the quick brown fox';
      const b = 'the slow brown bear';
      final d = computeIntralineDiff(a, b);
      for (final ranges in [d.oldRanges, d.newRanges]) {
        for (var i = 1; i < ranges.length; i++) {
          expect(ranges[i - 1].end <= ranges[i].start, isTrue);
        }
      }
    });

    test('very long lines fall back to affix trim without hanging', () {
      final a = '${'x' * 5000}A${'y' * 5000}';
      final b = '${'x' * 5000}B${'y' * 5000}';
      final d = computeIntralineDiff(a, b);
      // The single differing char is isolated by prefix/suffix trim.
      expect(d.oldRanges, [const IntralineRange(5000, 5001)]);
      expect(d.newRanges, [const IntralineRange(5000, 5001)]);
    });
  });
}
