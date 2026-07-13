// The context-expansion engine. A wrong offset here splices UNRELATED SOURCE
// LINES into a diff and renders them as though the commit contained them — so
// these tests care less about "does it expand" than about "does it ever lie".

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';
import 'package:remote_magic_git/features/common/patch_model.dart';

/// A 40-line file: `line 1` … `line 40`.
List<String> blobOf(int n) => [for (var i = 1; i <= n; i++) 'line $i'];

/// A patch touching `f.dart`, changing line 20 only (so git's -U3 gives context
/// 17-19 and 21-23), against the 40-line blob above.
const _patch =
    'commit abc\n'
    'Author: Dev <d@e>\n'
    '\n'
    '    subject\n'
    '\n'
    'diff --git a/f.dart b/f.dart\n'
    'index 111..222 100644\n'
    '--- a/f.dart\n'
    '+++ b/f.dart\n'
    '@@ -17,7 +17,7 @@\n'
    ' line 17\n'
    ' line 18\n'
    ' line 19\n'
    '-line 20\n'
    '+line 20\n'
    ' line 21\n'
    ' line 22\n'
    ' line 23\n';

List<String> textsOf(List<PatchRow> rows) => [
  for (final r in rows)
    switch (r) {
      PreambleRow(:final text) => text,
      FileHeaderRow(:final text) => text,
      HunkHeaderRow(:final text) => text,
      CodeRow(:final text) => text,
      ExpanderRow(:final hiddenLines) => '⋯$hiddenLines',
    },
];

void main() {
  group('gaps and expanders', () {
    test('an unexpanded patch shows an expander above and below the hunk', () {
      final patch = parseCommitPatch(_patch);
      final rows = buildPatchRows(patch, blobs: {0: blobOf(40)});
      final texts = textsOf(rows);

      // Lines 1-16 hidden above the hunk; lines 24-40 hidden below it.
      expect(texts, contains('⋯16'));
      expect(texts, contains('⋯17'));
      expect(texts.where((t) => t.startsWith('⋯')), hasLength(2));
    });

    test('expanding down from the top of a gap reveals the first lines', () {
      final patch = parseCommitPatch(_patch);
      final rows = buildPatchRows(
        patch,
        blobs: {0: blobOf(40)},
        expansions: {
          const ExpandRequest(0, 0): const GapExpansion(fromTop: 3),
        },
      );
      final texts = textsOf(rows);
      // The gap runs 1..16; revealing 3 from the top gives lines 1,2,3 — as
      // CONTEXT rows (leading space), because that's what they are.
      expect(texts, containsAllInOrder([' line 1', ' line 2', ' line 3', '⋯13']));
    });

    test('expanding up reveals the lines immediately above the hunk', () {
      final patch = parseCommitPatch(_patch);
      final rows = buildPatchRows(
        patch,
        blobs: {0: blobOf(40)},
        expansions: {
          const ExpandRequest(0, 0): const GapExpansion(fromBottom: 2),
        },
      );
      final texts = textsOf(rows);
      // Gap 1..16, revealing 2 from the bottom → lines 15 and 16, sitting
      // directly above the @@ header. Off-by-one here would show 14/15.
      expect(
        texts,
        containsAllInOrder(['⋯14', ' line 15', ' line 16', '@@ -17,7 +17,7 @@']),
      );
    });

    test('a fully-expanded gap leaves no expander behind', () {
      final patch = parseCommitPatch(_patch);
      final rows = buildPatchRows(
        patch,
        blobs: {0: blobOf(40)},
        expansions: {
          const ExpandRequest(0, 0): const GapExpansion(fromTop: 16),
          const ExpandRequest(0, 1): const GapExpansion(fromTop: 17),
        },
      );
      final texts = textsOf(rows);
      expect(texts.where((t) => t.startsWith('⋯')), isEmpty);
      expect(texts, contains(' line 1'));
      expect(texts, contains(' line 40'), reason: 'to the end of the file');
    });

    test('the trailing gap ends at the last line of the file, not past it', () {
      final patch = parseCommitPatch(_patch);
      final rows = buildPatchRows(
        patch,
        blobs: {0: blobOf(40)},
        expansions: {
          const ExpandRequest(0, 1): const GapExpansion(fromTop: 99),
        },
      );
      final texts = textsOf(rows);
      expect(texts.last, ' line 40');
      expect(texts, isNot(contains(' ')), reason: 'no empty past-the-end rows');
    });

    test('adjacent hunks produce no expander between them', () {
      const adjacent =
          'diff --git a/f.dart b/f.dart\n'
          '--- a/f.dart\n'
          '+++ b/f.dart\n'
          '@@ -1,2 +1,2 @@\n'
          '-line 1\n'
          '+line 1\n'
          ' line 2\n'
          '@@ -3,2 +3,2 @@\n'
          '-line 3\n'
          '+line 3\n'
          ' line 4\n';
      final rows = buildPatchRows(
        parseCommitPatch(adjacent),
        blobs: {0: blobOf(4)},
      );
      final gaps = rows.whereType<ExpanderRow>().toList();
      // Hunk one covers 1-2, hunk two starts at 3: they touch. The only gap is
      // the (empty) trailing one, which must also not appear.
      expect(gaps, isEmpty);
    });

    test('a small gap offers expand-all; a huge one does not', () {
      final patch = parseCommitPatch(_patch);
      final small = buildPatchRows(patch, blobs: {0: blobOf(40)})
          .whereType<ExpanderRow>()
          .first;
      expect(small.hiddenLines, 16);
      expect(small.canAll, isTrue, reason: '16 ≤ the small-gap threshold');

      // Same patch against a 5000-line file → the trailing gap is enormous.
      final big = buildPatchRows(patch, blobs: {0: blobOf(5000)})
          .whereType<ExpanderRow>()
          .last;
      expect(big.hiddenLines, greaterThan(kExpandAllMaxLines));
      expect(big.canAll, isFalse, reason: 'one click must not build 5k rows');
    });

    test('the leading gap only walks up; the trailing gap only walks down', () {
      final rows = buildPatchRows(
        parseCommitPatch(_patch),
        blobs: {0: blobOf(40)},
      ).whereType<ExpanderRow>().toList();
      expect(rows.first.canUp, isTrue);
      expect(rows.first.canDown, isFalse, reason: 'nothing above the file');
      expect(rows.last.canDown, isTrue);
      expect(rows.last.canUp, isFalse, reason: 'nothing below the file');
    });
  });

  group('files that must not expand', () {
    test('a file whose blob has not loaded shows the affordance, no lines', () {
      final rows = buildPatchRows(parseCommitPatch(_patch), blobs: const {});
      expect(rows.whereType<ExpanderRow>(), isNotEmpty);
      expect(
        rows.whereType<CodeRow>().where((r) => r.fromExpansion),
        isEmpty,
        reason: 'no blob → nothing spliced, ever',
      );
    });

    test('a deleted file gets no expanders at all', () {
      const deleted =
          'diff --git a/g.dart b/g.dart\n'
          'deleted file mode 100644\n'
          '--- a/g.dart\n'
          '+++ /dev/null\n'
          '@@ -1,2 +0,0 @@\n'
          '-a\n'
          '-b\n';
      final rows = buildPatchRows(parseCommitPatch(deleted));
      expect(rows.whereType<ExpanderRow>(), isEmpty);
    });

    test('a merge (combined) diff gets no expanders', () {
      const combined =
          'diff --cc lib/a.dart\n'
          '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@@ -1,2 -1,2 +1,3 @@@\n'
          '  ctx\n'
          '++merged\n';
      final rows = buildPatchRows(parseCommitPatch(combined));
      expect(rows.whereType<ExpanderRow>(), isEmpty);
    });
  });

  group('verifyBlobMatchesHunks — the check that stops it lying', () {
    test('accepts the blob the hunks were actually computed against', () {
      final file = parseCommitPatch(_patch).files.single;
      expect(verifyBlobMatchesHunks(file, blobOf(40)), isTrue);
    });

    test('rejects a blob whose content is shifted by even one line', () {
      final file = parseCommitPatch(_patch).files.single;
      // The wrong revision of the file: everything moved down by one. The line
      // numbers still exist, so a naive splice would happily render line 16's
      // text as line 17 — silently wrong code.
      final shifted = ['inserted at top', ...blobOf(40)];
      expect(
        verifyBlobMatchesHunks(file, shifted),
        isFalse,
        reason: 'context lines no longer sit where the header says they do',
      );
    });

    test('rejects a blob that is too short for the hunk', () {
      final file = parseCommitPatch(_patch).files.single;
      expect(verifyBlobMatchesHunks(file, blobOf(5)), isFalse);
    });

    test('rejects a different file entirely (the rename trap)', () {
      final file = parseCommitPatch(_patch).files.single;
      final other = [for (var i = 1; i <= 40; i++) 'totally different $i'];
      expect(verifyBlobMatchesHunks(file, other), isFalse);
    });

    test('a hunk with no newline at EOF still verifies', () {
      const noNewline =
          'diff --git a/f.dart b/f.dart\n'
          '--- a/f.dart\n'
          '+++ b/f.dart\n'
          '@@ -1,1 +1,1 @@\n'
          '-old\n'
          '+new\n'
          '\\ No newline at end of file\n';
      final file = parseCommitPatch(noNewline).files.single;
      expect(verifyBlobMatchesHunks(file, ['new']), isTrue);
    });
  });
}
