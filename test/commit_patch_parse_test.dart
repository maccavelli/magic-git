// Parsing a whole `git show` patch: the commit preamble, one DiffFile per file,
// and the `@@` line-number arithmetic that context expansion is computed from.
// The nasty cases live here — a wrong range splices the WRONG SOURCE LINES into
// a diff and presents them as real, which is far worse than showing too few.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';

void main() {
  group('hunk headers', () {
    test('parses both ranges', () {
      expect(
        parseHunkHeader('@@ -158,7 +158,9 @@ class Foo {'),
        const HunkRange(oldStart: 158, oldCount: 7, newStart: 158, newCount: 9),
      );
    });

    test('an omitted count means one line', () {
      expect(
        parseHunkHeader('@@ -5 +7 @@'),
        const HunkRange(oldStart: 5, oldCount: 1, newStart: 7, newCount: 1),
      );
    });

    test('a zero count survives as zero (insertion into an empty file)', () {
      final r = parseHunkHeader('@@ -0,0 +1,3 @@')!;
      expect(r.oldCount, 0);
      expect(r.newStart, 1);
      expect(r.newEnd, 4, reason: 'one past the last line covered');
    });

    test('a combined (merge) hunk header is NOT understood', () {
      // `git show --cc` emits three-sided hunks. Pretending to parse one would
      // make the arithmetic silently wrong, so it must come back null and the
      // file must refuse to expand.
      expect(parseHunkHeader('@@@ -1,2 -1,2 +1,3 @@@'), isNull);
      expect(parseHunkHeader('not a hunk'), isNull);
    });
  });

  group('post-image line counting', () {
    test('counts adds and context, not removes', () {
      const hunk = DiffHunk('@@ -1,2 +1,2 @@', [' ctx', '-gone', '+added']);
      expect(hunk.postImageLineCount, 2);
    });

    test('"\\ No newline at end of file" is not a file line', () {
      // Counting the marker would push every expansion below it off by one.
      const hunk = DiffHunk('@@ -1,1 +1,1 @@', [
        '-old',
        '+new',
        '\\ No newline at end of file',
      ]);
      expect(hunk.postImageLineCount, 1);
    });
  });

  group('parseCommitPatch', () {
    test('splits the preamble from one DiffFile per file', () {
      const raw =
          'commit abc123\n'
          'Author: Dev <d@e>\n'
          '\n'
          '    the subject\n'
          '\n'
          'diff --git a/lib/a.dart b/lib/a.dart\n'
          'index 111..222 100644\n'
          '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@ -1,2 +1,3 @@\n'
          ' one\n'
          '+two\n'
          ' three\n'
          'diff --git a/lib/b.dart b/lib/b.dart\n'
          'index 333..444 100644\n'
          '--- a/lib/b.dart\n'
          '+++ b/lib/b.dart\n'
          '@@ -10,1 +10,1 @@\n'
          '-x\n'
          '+y\n';
      final patch = parseCommitPatch(raw);

      expect(patch.preamble.first, 'commit abc123');
      expect(patch.files, hasLength(2));
      expect(patch.files[0].newPath, 'lib/a.dart');
      expect(patch.files[1].newPath, 'lib/b.dart');
      expect(patch.files[1].hunks.single.range!.newStart, 10);
      expect(patch.files.every((f) => f.canExpand), isTrue);
    });

    test(
      'a merge commit (preamble, no diff) parses as complete, not failed',
      () {
        final patch = parseCommitPatch(
          'commit abc\nMerge: 111 222\n\n    Merge branch x\n',
        );
        expect(patch.files, isEmpty);
        expect(patch.preamble, isNotEmpty);
      },
    );
  });

  group('change classification decides what can expand', () {
    DiffFile only(String raw) => parseCommitPatch(raw).files.single;

    test(
      'an added file has no pre-image, and still expands from the new blob',
      () {
        final f = only(
          'diff --git a/n.dart b/n.dart\n'
          'new file mode 100644\n'
          '--- /dev/null\n'
          '+++ b/n.dart\n'
          '@@ -0,0 +1,2 @@\n'
          '+a\n'
          '+b\n',
        );
        expect(f.change, DiffFileChange.added);
        expect(f.oldPath, isNull);
        expect(f.newPath, 'n.dart');
        expect(f.canExpand, isTrue);
      },
    );

    test('a deleted file cannot expand — there is no post-image blob', () {
      final f = only(
        'diff --git a/g.dart b/g.dart\n'
        'deleted file mode 100644\n'
        '--- a/g.dart\n'
        '+++ /dev/null\n'
        '@@ -1,2 +0,0 @@\n'
        '-a\n'
        '-b\n',
      );
      expect(f.change, DiffFileChange.deleted);
      expect(f.canExpand, isFalse);
    });

    test('a rename keeps BOTH paths distinct', () {
      // Reading the post-image at the OLD path would splice a different file's
      // contents into the diff.
      final f = only(
        'diff --git a/old.dart b/new.dart\n'
        'similarity index 90%\n'
        'rename from old.dart\n'
        'rename to new.dart\n'
        '--- a/old.dart\n'
        '+++ b/new.dart\n'
        '@@ -1,1 +1,1 @@\n'
        '-a\n'
        '+b\n',
      );
      expect(f.change, DiffFileChange.renamed);
      expect(f.oldPath, 'old.dart');
      expect(f.newPath, 'new.dart');
      expect(f.canExpand, isTrue);
    });

    test('a binary file has no hunks and cannot expand', () {
      final f = only(
        'diff --git a/i.png b/i.png\n'
        'index 111..222 100644\n'
        'Binary files a/i.png and b/i.png differ\n',
      );
      expect(f.change, DiffFileChange.binary);
      expect(f.oldPath, 'i.png');
      expect(f.newPath, 'i.png');
      expect(f.hunks, isEmpty);
      expect(f.canExpand, isFalse);
    });

    test('a binary path containing spaces and "and" remains exact', () {
      final f = only(
        'diff --git a/a and b x.png b/a and b x.png\n'
        'index 111..222 100644\n'
        'Binary files a/a and b x.png and b/a and b x.png differ\n',
      );
      expect(f.oldPath, 'a and b x.png');
      expect(f.newPath, 'a and b x.png');
    });

    test('a combined merge diff parses but refuses to expand', () {
      final f = only(
        'diff --cc lib/a.dart\n'
        'index 111,222..333\n'
        '--- a/lib/a.dart\n'
        '+++ b/lib/a.dart\n'
        '@@@ -1,2 -1,2 +1,3 @@@\n'
        '  ctx\n'
        '++merged\n',
      );
      expect(f.hunks.single.range, isNull);
      expect(
        f.canExpand,
        isFalse,
        reason: 'three-sided arithmetic is not ours',
      );
    });
  });

  test('a copy header is classified, not left looking modified', () {
    // 0022 L4. `git diff -C` (or a host diff.renames=copies, or an imported
    // patch) emits copy headers. Without handling them a copied file fell
    // through to `modified` while carrying oldPath != newPath — a combination
    // no other parse path produces, so any consumer assuming
    // "modified => same path" was wrong for copies.
    const raw = '''diff --git a/src.dart b/dst.dart
similarity index 95%
copy from src.dart
copy to dst.dart
--- a/src.dart
+++ b/dst.dart
@@ -1,2 +1,2 @@
 keep
-old
+new
''';
    final file = parseCommitPatch(raw).files.single;
    expect(file.change, DiffFileChange.renamed);
    expect(file.oldPath, 'src.dart');
    expect(file.newPath, 'dst.dart');
  });
}
