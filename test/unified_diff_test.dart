import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';

const _modified =
    'diff --git a/lib/a.dart b/lib/a.dart\n'
    'index 1111111..2222222 100644\n'
    '--- a/lib/a.dart\n'
    '+++ b/lib/a.dart\n'
    '@@ -1,3 +1,3 @@\n'
    ' line1\n'
    '-old2\n'
    '+new2\n'
    ' line3\n'
    '@@ -10,2 +10,3 @@\n'
    ' x\n'
    '+added\n'
    ' y\n';

void main() {
  test('parses header and multiple hunks', () {
    final f = parseUnifiedDiff(_modified)!;
    expect(f.header, [
      'diff --git a/lib/a.dart b/lib/a.dart',
      'index 1111111..2222222 100644',
      '--- a/lib/a.dart',
      '+++ b/lib/a.dart',
    ]);
    expect(f.hunks, hasLength(2));
    expect(f.hunks[0].header, '@@ -1,3 +1,3 @@');
    expect(f.hunks[0].lines, [' line1', '-old2', '+new2', ' line3']);
    expect(f.hunks[1].header, '@@ -10,2 +10,3 @@');
    expect(f.hunks[1].lines, [' x', '+added', ' y']);
  });

  test('classifies line kinds', () {
    expect(diffLineKind(' ctx'), DiffLineKind.context);
    expect(diffLineKind('+add'), DiffLineKind.add);
    expect(diffLineKind('-del'), DiffLineKind.remove);
    expect(diffLineKind(r'\ No newline at end of file'), DiffLineKind.noNewline);
    expect(diffLineKind(''), DiffLineKind.context);
  });

  test('buildHunkPatch re-emits header + a single hunk, byte-exact', () {
    final f = parseUnifiedDiff(_modified)!;
    final patch = buildHunkPatch(f, f.hunks[1]);
    expect(
      patch,
      'diff --git a/lib/a.dart b/lib/a.dart\n'
      'index 1111111..2222222 100644\n'
      '--- a/lib/a.dart\n'
      '+++ b/lib/a.dart\n'
      '@@ -10,2 +10,3 @@\n'
      ' x\n'
      '+added\n'
      ' y\n',
    );
  });

  test('handles a new file (--- /dev/null)', () {
    const raw =
        'diff --git a/new.txt b/new.txt\n'
        'new file mode 100644\n'
        'index 0000000..abc1234\n'
        '--- /dev/null\n'
        '+++ b/new.txt\n'
        '@@ -0,0 +1,2 @@\n'
        '+hello\n'
        '+world\n';
    final f = parseUnifiedDiff(raw)!;
    expect(f.header, contains('new file mode 100644'));
    expect(f.header, contains('--- /dev/null'));
    expect(f.hunks.single.lines, ['+hello', '+world']);
  });

  test('preserves the "no newline at end of file" marker', () {
    const raw =
        'diff --git a/f b/f\n'
        'index 111..222 100644\n'
        '--- a/f\n'
        '+++ b/f\n'
        '@@ -1 +1 @@\n'
        '-a\n'
        r'\ No newline at end of file'
        '\n'
        '+b\n'
        r'\ No newline at end of file'
        '\n';
    final f = parseUnifiedDiff(raw)!;
    final patch = buildHunkPatch(f, f.hunks.single);
    expect(patch, endsWith('+b\n\\ No newline at end of file\n'));
    expect(patch, raw); // round-trips exactly
  });

  test('preserves CRLF bytes on body lines', () {
    const raw =
        'diff --git a/f b/f\n'
        'index 1..2 100644\n'
        '--- a/f\n'
        '+++ b/f\n'
        '@@ -1,2 +1,2 @@\n'
        ' keep\r\n'
        '-old\r\n'
        '+new\r\n';
    final f = parseUnifiedDiff(raw)!;
    expect(f.hunks.single.lines, [' keep\r', '-old\r', '+new\r']);
    expect(buildHunkPatch(f, f.hunks.single), raw);
  });

  test('returns null for empty and hunkless (binary) diffs', () {
    expect(parseUnifiedDiff(''), isNull);
    expect(parseUnifiedDiff('   \n'), isNull);
    expect(
      parseUnifiedDiff(
        'diff --git a/img.png b/img.png\n'
        'index 111..222 100644\n'
        'Binary files a/img.png and b/img.png differ\n',
      ),
      isNull,
    );
  });
}
