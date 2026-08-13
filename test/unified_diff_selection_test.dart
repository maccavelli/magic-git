import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';

const _mixed = '''diff --git a/example.txt b/example.txt
index 1111111..2222222 100644
--- a/example.txt
+++ b/example.txt
@@ -1,6 +1,7 @@ section
 keep one
-remove one
+add one
-remove two
+add two
 keep two
+tail
 keep three
''';

DiffFile get _file => parseUnifiedDiff(_mixed)!;

void main() {
  test('selected addition is retained and other additions are omitted', () {
    final result = buildSelectionPatch(_file, const {
      0: {2},
    });
    expect(result, isA<SelectionPatchBuilt>());
    final patch = (result as SelectionPatchBuilt).patch;
    expect(patch, contains('+add one'));
    expect(patch, isNot(contains('+add two')));
    expect(patch, isNot(contains('+tail')));
    expect(patch, contains(' remove one'));
    expect(patch, contains(' remove two'));
    expect(patch, contains('@@ -1,5 +1,6 @@ section'));
  });

  test('selected removal stays removal and unselected removal is context', () {
    final result = buildSelectionPatch(_file, const {
      0: {1},
    });
    final patch = (result as SelectionPatchBuilt).patch;
    expect(patch, contains('-remove one'));
    expect(patch, contains(' remove two'));
    expect(patch, contains('@@ -1,5 +1,4 @@ section'));
  });

  test('adjacent add/remove selection recomputes both ranges', () {
    final result = buildSelectionPatch(_file, const {
      0: {1, 2, 3, 4},
    });
    final patch = (result as SelectionPatchBuilt).patch;
    expect(patch, contains('@@ -1,5 +1,5 @@ section'));
    expect((result).selectedLineCount, 4);
  });

  test('literal header paths including dash and glob characters survive', () {
    const raw = '''diff --git a/-[x]*.txt b/-[x]*.txt
index 1111111..2222222 100644
--- a/-[x]*.txt
+++ b/-[x]*.txt
@@ -1 +1 @@
-old
+new
''';
    final file = parseUnifiedDiff(raw)!;
    final patch =
        (buildSelectionPatch(file, const {
                  0: {1},
                })
                as SelectionPatchBuilt)
            .patch;
    expect(patch, startsWith('diff --git a/-[x]*.txt b/-[x]*.txt'));
    expect(patch, contains('--- a/-[x]*.txt\n+++ b/-[x]*.txt'));
  });

  test('Unicode and no-newline markers are retained', () {
    const raw = '''diff --git a/unicode.txt b/unicode.txt
index 1111111..2222222 100644
--- a/unicode.txt
+++ b/unicode.txt
@@ -1 +1 @@
-café
\\ No newline at end of file
+café ☕
\\ No newline at end of file
''';
    final patch =
        (buildSelectionPatch(parseUnifiedDiff(raw)!, const {
                  0: {2},
                })
                as SelectionPatchBuilt)
            .patch;
    expect(patch, contains('+café ☕'));
    expect(patch, contains('\\ No newline at end of file'));
  });

  test('no-newline marker for an omitted addition is omitted with it', () {
    const raw = '''diff --git a/eof.txt b/eof.txt
index 1111111..2222222 100644
--- a/eof.txt
+++ b/eof.txt
@@ -1,2 +1,2 @@
-old
+new
\\ No newline at end of file
 keep
''';
    final patch =
        (buildSelectionPatch(parseUnifiedDiff(raw)!, const {
                  0: {0},
                })
                as SelectionPatchBuilt)
            .patch;
    expect(patch, contains('-old'));
    expect(patch, isNot(contains('+new')));
    expect(patch, isNot(contains('\\ No newline at end of file')));
  });

  test('new and deleted file patches remain structurally selectable', () {
    const added = '''diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
''';
    const deleted = '''diff --git a/old.txt b/old.txt
deleted file mode 100644
--- a/old.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
''';
    expect(
      buildSelectionPatch(parseUnifiedDiff(added)!, const {
        0: {0},
      }),
      isA<SelectionPatchBuilt>(),
    );
    expect(
      buildSelectionPatch(parseUnifiedDiff(deleted)!, const {
        0: {1},
      }),
      isA<SelectionPatchBuilt>(),
    );
  });

  test('cross-hunk and non-change selections are typed failures', () {
    final cross = DiffFile(
      _file.header,
      [_file.hunks.single, _file.hunks.single],
      oldPath: _file.oldPath,
      newPath: _file.newPath,
    );
    expect(
      (buildSelectionPatch(cross, const {
                0: {1},
                1: {2},
              })
              as SelectionPatchUnsupported)
          .reason,
      SelectionPatchUnsupportedReason.crossHunkSelection,
    );
    expect(
      (buildSelectionPatch(_file, const {
                0: {0},
              })
              as SelectionPatchUnsupported)
          .reason,
      SelectionPatchUnsupportedReason.nonChangeLine,
    );
  });

  test('combined and malformed hunks return typed reasons', () {
    final combined = DiffFile(_file.header, const [
      DiffHunk('@@@ -1,1 -1,1 +1,1 @@@', ['++line']),
    ]);
    final malformed = DiffFile(_file.header, const [
      DiffHunk('@@ nope @@', ['+line']),
    ]);
    expect(
      (buildSelectionPatch(combined, const {
                0: {0},
              })
              as SelectionPatchUnsupported)
          .reason,
      SelectionPatchUnsupportedReason.combinedDiff,
    );
    expect(
      (buildSelectionPatch(malformed, const {
                0: {0},
              })
              as SelectionPatchUnsupported)
          .reason,
      SelectionPatchUnsupportedReason.malformedHunk,
    );
  });
}
