/// The row model behind the commit-patch viewer, and the engine that expands a
/// hunk's context by splicing lines from the file's blob.
///
/// Why this exists: git emits three context lines around a change, so hunks end
/// mid-expression and read as a truncated diff. Revealing more means going back
/// to the file as the commit left it and pulling the surrounding lines in — the
/// same `⋯` affordance GitHub and GitLens have.
///
/// Everything here is pure: a [CommitPatch] plus the blobs plus a set of
/// expansions in, a flat list of rows out. That's deliberate — the arithmetic is
/// where this can go catastrophically wrong (splice the wrong offset and you
/// render *the wrong source code* as though it were part of the commit), so it
/// is all reachable from unit tests with no widget in sight.
library;

import '../../core/git/unified_diff.dart';

/// A row in the rendered patch. Every row is exactly one text line tall, which
/// keeps the viewer's fixed item extent (and its O(1) scroll math) intact.
sealed class PatchRow {
  const PatchRow();
}

/// A line of the commit preamble (`commit …`, `Author: …`, the message).
class PreambleRow extends PatchRow {
  final String text;
  const PreambleRow(this.text);
}

/// A line of a file's header block (`diff --git`, `index`, `---`, `+++`).
class FileHeaderRow extends PatchRow {
  final String text;

  /// Index into [CommitPatch.files] — the file this header opens.
  final int fileIndex;
  const FileHeaderRow(this.text, this.fileIndex);
}

/// A `@@ … @@` hunk header.
class HunkHeaderRow extends PatchRow {
  final String text;
  const HunkHeaderRow(this.text);
}

/// A line of code: either from the patch itself, or one spliced in from the
/// blob by an expansion ([fromExpansion] — rendered as context, because that is
/// what it is: unchanged surrounding code).
class CodeRow extends PatchRow {
  final String text;
  final bool fromExpansion;

  /// Which of the patch's files this line belongs to — lets the viewer group a
  /// file's code rows and syntax-highlight them against that file's language.
  final int fileIndex;
  const CodeRow(this.text, {this.fromExpansion = false, this.fileIndex = 0});
}

/// A clickable row standing for lines that exist in the file but aren't in the
/// patch. Tapping it opens the gap ([ExpandRequest]).
///
/// It carries a single chevron, pointing **down**: one control, one direction,
/// one meaning — "reveal what's below this line". Its counterpart once the gap
/// is open is [CollapseRow], whose chevron points up. Two arrows on one row said
/// nothing about what a click would do.
class ExpanderRow extends PatchRow {
  /// How many post-image lines are still hidden in this gap. `null` means
  /// "unknown, runs to the end of the file" — only for the trailing expander,
  /// before the blob has been fetched.
  final int? hiddenLines;

  /// True when one click reveals the rest of the gap. False only for a gap so
  /// large that filling it would build tens of thousands of rows in a frame
  /// (see [kExpandAllMaxLines]); those are walked [kExpandStep] at a time.
  final bool expandsAll;

  /// What a click does. [ExpandDirection.all] fills the gap; otherwise it walks
  /// from the end nearest the code being read — down from the hunk above, or up
  /// from the hunk below when there is no hunk above (the leading gap).
  final ExpandDirection direction;

  final ExpandRequest request;

  const ExpanderRow({
    required this.hiddenLines,
    required this.expandsAll,
    required this.direction,
    required this.request,
  });
}

/// The chevron-up twin of [ExpanderRow]: it sits at the head of the lines a gap
/// has revealed, and closes them again. Revealing must be undoable — an opened
/// gap that can't be shut just buries the change the reader came for.
class CollapseRow extends PatchRow {
  /// How many lines this gap is currently showing.
  final int revealedLines;

  final ExpandRequest request;

  const CollapseRow({required this.revealedLines, required this.request});
}

/// Which gap an expansion applies to: the gap *before* hunk [hunkIndex] of file
/// [fileIndex]. A gap index equal to the file's hunk count is the trailing gap
/// (after the last hunk, to end of file).
class ExpandRequest {
  final int fileIndex;
  final int gapIndex;
  const ExpandRequest(this.fileIndex, this.gapIndex);

  @override
  bool operator ==(Object other) =>
      other is ExpandRequest &&
      other.fileIndex == fileIndex &&
      other.gapIndex == gapIndex;

  @override
  int get hashCode => Object.hash(fileIndex, gapIndex);
}

/// Which way a gap is being opened.
enum ExpandDirection { up, down, all }

/// How many lines one click reveals when a gap is too big to open whole.
const int kExpandStep = 20;

/// Guards "reveal the rest" on a pathological file: filling a 40k-line gap at
/// once would build 40k rows in a single frame. Above this, the gap is walked
/// [kExpandStep] lines per click instead.
const int kExpandAllMaxLines = 2000;

/// How much of a gap has been revealed, from each end.
class GapExpansion {
  /// Lines revealed downward from the top of the gap.
  final int fromTop;

  /// Lines revealed upward from the bottom of the gap.
  final int fromBottom;

  const GapExpansion({this.fromTop = 0, this.fromBottom = 0});

  /// Opens the gap further. [hidden] is what's *still* hidden right now, which
  /// is the only thing [ExpandDirection.all] needs to finish the job — adding it
  /// to whatever is already shown covers the gap exactly, whether this is the
  /// first click or the last of a long walk.
  GapExpansion plus(ExpandDirection direction, int hidden) => switch (direction) {
    // "Up" means revealing the lines just above the hunk below — i.e. growing
    // from the BOTTOM of the gap upward.
    ExpandDirection.up => GapExpansion(
      fromTop: fromTop,
      fromBottom: fromBottom + kExpandStep,
    ),
    ExpandDirection.down => GapExpansion(
      fromTop: fromTop + kExpandStep,
      fromBottom: fromBottom,
    ),
    ExpandDirection.all => GapExpansion(
      fromTop: fromTop + hidden,
      fromBottom: fromBottom,
    ),
  };

  /// True once the two ends have met — the gap is fully revealed.
  bool covers(int gapSize) => fromTop + fromBottom >= gapSize;
}

/// The blobs an expansion needs, keyed by file index: the post-image contents,
/// already split into lines. Absent (or null) means "not fetched yet / not
/// available", and that file simply shows unexpanded — never wrong lines.
typedef BlobLines = Map<int, List<String>?>;

/// Builds the flat row list for a whole commit patch.
///
/// [expansions] says how far each gap has been opened; [blobs] supplies the
/// post-image lines to splice. A gap whose blob isn't loaded still renders its
/// expander (so the affordance is visible immediately) — it just can't fill yet.
List<PatchRow> buildPatchRows(
  CommitPatch patch, {
  Map<ExpandRequest, GapExpansion> expansions = const {},
  BlobLines blobs = const {},
}) {
  final rows = <PatchRow>[
    for (final line in patch.preamble) PreambleRow(line),
  ];

  for (var f = 0; f < patch.files.length; f++) {
    final file = patch.files[f];
    for (final line in file.header) {
      rows.add(FileHeaderRow(line, f));
    }

    final blob = file.canExpand ? blobs[f] : null;

    for (var h = 0; h < file.hunks.length; h++) {
      final hunk = file.hunks[h];
      final range = hunk.range;

      // The gap above this hunk: from the end of the previous hunk (or the top
      // of the file) to this hunk's first line.
      if (file.canExpand && range != null) {
        final gapStart = h == 0
            ? 1
            : file.hunks[h - 1].range!.newEnd; // 1-based, inclusive
        final gapEnd = range.newStart; // exclusive
        _emitGap(
          rows,
          fileIndex: f,
          gapIndex: h,
          gapStart: gapStart,
          gapEnd: gapEnd,
          expansion: expansions[ExpandRequest(f, h)] ?? const GapExpansion(),
          blob: blob,
          isLeading: h == 0,
        );
      }

      rows.add(HunkHeaderRow(hunk.header));
      for (final line in hunk.lines) {
        rows.add(CodeRow(line, fileIndex: f));
      }
    }

    // The trailing gap: from the end of the last hunk to the end of the file.
    if (file.canExpand && file.hunks.isNotEmpty) {
      final last = file.hunks.last.range!;
      final gapIndex = file.hunks.length;
      // Without the blob we don't know how long the file is, so the size is
      // unknown — the expander still shows, and resolves once the blob lands.
      final gapEnd = blob == null ? null : blob.length + 1;
      if (gapEnd == null || gapEnd > last.newEnd) {
        _emitGap(
          rows,
          fileIndex: f,
          gapIndex: gapIndex,
          gapStart: last.newEnd,
          gapEnd: gapEnd ?? last.newEnd, // unknown → size unknown below
          expansion:
              expansions[ExpandRequest(f, gapIndex)] ?? const GapExpansion(),
          blob: blob,
          isTrailing: true,
          unknownSize: gapEnd == null,
        );
      }
    }
  }
  return rows;
}

/// Emits one gap: a collapse row if anything is revealed, the revealed lines
/// themselves, and an expander for whatever is still hidden. Nothing is emitted
/// for an empty gap (two hunks that touch).
void _emitGap(
  List<PatchRow> rows, {
  required int fileIndex,
  required int gapIndex,
  required int gapStart, // 1-based, inclusive
  required int gapEnd, // 1-based, exclusive
  required GapExpansion expansion,
  required List<String>? blob,
  bool isLeading = false,
  bool isTrailing = false,
  bool unknownSize = false,
}) {
  final gapSize = unknownSize ? 0 : gapEnd - gapStart;
  if (!unknownSize && gapSize <= 0) return; // hunks are adjacent — no gap

  final request = ExpandRequest(fileIndex, gapIndex);

  // Which end a stepped click walks from: the one against the code being read.
  // The leading gap has no hunk above it, so it grows upward from the hunk
  // below; every other gap grows downward from the hunk above.
  final step = isLeading ? ExpandDirection.up : ExpandDirection.down;

  // Blob absent: show the affordance, reveal nothing. It resolves the moment
  // the blob lands — the row is here so the gap is visibly openable, which is
  // the whole point (a hunk that just stops looks truncated).
  if (blob == null) {
    rows.add(
      ExpanderRow(
        hiddenLines: unknownSize ? null : gapSize,
        // Size unknown → can't promise to open the whole thing in one click.
        expandsAll: !unknownSize && gapSize <= kExpandAllMaxLines,
        direction: (!unknownSize && gapSize <= kExpandAllMaxLines)
            ? ExpandDirection.all
            : step,
        request: request,
      ),
    );
    return;
  }

  final shownTop = expansion.fromTop.clamp(0, gapSize);
  final shownBottom = expansion.fromBottom.clamp(0, gapSize - shownTop);
  final shown = shownTop + shownBottom;
  final hidden = gapSize - shown;

  // The way back. It heads the revealed block so it's found where the gap was.
  if (shown > 0) {
    rows.add(CollapseRow(revealedLines: shown, request: request));
  }

  // Lines revealed from the top of the gap, downward.
  for (var i = 0; i < shownTop; i++) {
    rows.add(_blobRow(blob, gapStart + i, fileIndex));
  }

  if (hidden > 0) {
    final all = hidden <= kExpandAllMaxLines;
    rows.add(
      ExpanderRow(
        hiddenLines: hidden,
        expandsAll: all,
        direction: all ? ExpandDirection.all : step,
        request: request,
      ),
    );
  }

  // Lines revealed from the bottom of the gap, upward.
  for (var i = 0; i < shownBottom; i++) {
    rows.add(_blobRow(blob, gapEnd - shownBottom + i, fileIndex));
  }
}

/// One blob line as a context row. [lineNumber] is 1-based; a number outside
/// the blob yields nothing renderable rather than throwing — belt and braces,
/// since [verifyBlobMatchesHunks] should already have caught the disagreement.
CodeRow _blobRow(List<String> blob, int lineNumber, int fileIndex) {
  final i = lineNumber - 1;
  final text = (i >= 0 && i < blob.length) ? blob[i] : '';
  // Rendered as a context line: prefix it the way git would, so the viewer's
  // existing per-line coloring treats it as unchanged code.
  return CodeRow(' $text', fromExpansion: true, fileIndex: fileIndex);
}

/// Confirms the blob really is the post-image the hunks were computed against,
/// by checking every hunk's own context and added lines against the blob at the
/// line numbers the hunk header claims.
///
/// This is the load-bearing safety check. If the blob and the patch disagree
/// (wrong revision, wrong path after a rename, a `-w` diff, CRLF weirdness),
/// splicing would inject *unrelated source lines* into the middle of a diff and
/// present them as the truth. Better to refuse to expand than to lie: a caller
/// that gets `false` must not splice.
bool verifyBlobMatchesHunks(DiffFile file, List<String> blob) {
  for (final hunk in file.hunks) {
    final range = hunk.range;
    if (range == null) return false;

    var lineNumber = range.newStart; // 1-based line in the post-image
    for (final raw in hunk.lines) {
      switch (diffLineKind(raw)) {
        case DiffLineKind.remove:
        case DiffLineKind.noNewline:
          continue; // not in the post-image
        case DiffLineKind.add:
        case DiffLineKind.context:
        case DiffLineKind.other:
          final i = lineNumber - 1;
          if (i < 0 || i >= blob.length) return false;
          // Drop the leading marker; a bare empty line is a blank context line.
          final expected = raw.isEmpty ? '' : raw.substring(1);
          if (blob[i] != expected) return false;
          lineNumber++;
      }
    }
  }
  return true;
}
