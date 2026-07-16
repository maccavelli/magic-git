import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/intraline_diff.dart';
import '../../core/git/unified_diff.dart';
import '../viewer/code_view.dart' show CodeTheme;
import '../viewer/file_type.dart';
import '../viewer/syntax_highlighter.dart';
import 'diff_view.dart' show diffKindColor;

/// A syntax-coloured run within a diff line's *content* (marker excluded):
/// `[start, end)` carry the highlight.js [scope] (or null when unscoped). A
/// resolved, isolate-sendable form of one [HighlightedLine] run — the scope is
/// resolved to its style at paint via the active [CodeTheme].
class ScopedRun {
  final int start;
  final int end;
  final String? scope;
  const ScopedRun(this.start, this.end, this.scope);
}

/// Per-line render data for one diff-hunk body line: its [kind], the
/// syntax-highlighted content [runs] (null when the file's language is
/// unsupported/oversized — the content is then drawn in the kind's colour, as
/// before), and the intra-line [intraline] emphasis ranges (in content
/// coordinates) marking exactly what changed within a modified line.
///
/// All fields are isolate-sendable (ints/strings/enums), so this is produced in
/// the same parse pass that already moves off the UI isolate for huge diffs.
class DiffLineHighlight {
  final DiffLineKind kind;
  final List<ScopedRun>? runs;
  final List<IntralineRange> intraline;
  const DiffLineHighlight(this.kind, this.runs, this.intraline);
}

/// Above this many hunk-body lines, syntax highlighting is skipped (the content
/// still renders, coloured by kind). Mirrors the diff-parse isolate threshold's
/// intent: a regenerated lockfile or minified bundle shouldn't pay the
/// highlighter. Intra-line diffing is cheap and stays on regardless.
const int _highlightMaxLines = 6000;

/// Computes per-body-line [DiffLineHighlight]s for [file], one per hunk body
/// line in the order the hunks are flattened (all of hunk 0, then hunk 1, …) —
/// exactly the order [HunkDiffView] builds its line items.
///
/// Syntax highlighting reconstructs the pre- and post-images once and highlights
/// each whole (so multi-line grammar state — open strings, block comments — is
/// correct) then maps runs back to rows; it is gated by [enableHighlight] and
/// language support. Intra-line emphasis pairs each run of removed lines with the
/// run of added lines that follows it and diffs them content-to-content.
List<DiffLineHighlight> computeDiffLineHighlights(
  DiffFile file, {
  bool enableHighlight = true,
}) {
  final kinds = <DiffLineKind>[];
  final contents = <String>[];
  final side = <int>[]; // 0 = post image, 1 = pre image, -1 = neither
  final imageIndex = <int>[];
  final postContent = <String>[];
  final preContent = <String>[];

  for (final hunk in file.hunks) {
    for (final raw in hunk.lines) {
      final kind = diffLineKind(raw);
      final content = raw.isEmpty ? '' : raw.substring(1);
      kinds.add(kind);
      contents.add(content);
      switch (kind) {
        case DiffLineKind.context:
          side.add(0);
          imageIndex.add(postContent.length);
          postContent.add(content);
          preContent.add(content);
        case DiffLineKind.add:
          side.add(0);
          imageIndex.add(postContent.length);
          postContent.add(content);
        case DiffLineKind.remove:
          side.add(1);
          imageIndex.add(preContent.length);
          preContent.add(content);
        case DiffLineKind.noNewline:
        case DiffLineKind.other:
          side.add(-1);
          imageIndex.add(-1);
      }
    }
  }

  final total = kinds.length;

  // Syntax highlighting of each image, when the language is known and the diff
  // isn't enormous.
  HighlightedLines? postDoc;
  HighlightedLines? preDoc;
  final languageId = viewerFileTypeFor(file.newPath ?? file.oldPath ?? '')
      .languageId;
  if (enableHighlight &&
      total <= _highlightMaxLines &&
      languageId != null &&
      isLanguageSupported(languageId)) {
    if (postContent.isNotEmpty) {
      postDoc = highlightDoc(postContent.join('\n'), languageId);
    }
    if (preContent.isNotEmpty) {
      preDoc = highlightDoc(preContent.join('\n'), languageId);
    }
  }

  // Intra-line emphasis: within each hunk, pair each removed-line run with the
  // added-line run immediately following it and diff their contents.
  final intraline = List<List<IntralineRange>>.filled(total, const [], growable: false);
  var base = 0;
  for (final hunk in file.hunks) {
    final lines = hunk.lines;
    final n = lines.length;
    var i = 0;
    while (i < n) {
      if (diffLineKind(lines[i]) == DiffLineKind.remove) {
        final removeStart = i;
        while (i < n && diffLineKind(lines[i]) == DiffLineKind.remove) {
          i++;
        }
        final removeEnd = i;
        if (i < n && diffLineKind(lines[i]) == DiffLineKind.add) {
          final addStart = i;
          while (i < n && diffLineKind(lines[i]) == DiffLineKind.add) {
            i++;
          }
          final addEnd = i;
          final pairs = (removeEnd - removeStart) < (addEnd - addStart)
              ? removeEnd - removeStart
              : addEnd - addStart;
          for (var p = 0; p < pairs; p++) {
            final r = removeStart + p;
            final a = addStart + p;
            final d = computeIntralineDiff(
              lines[r].substring(1),
              lines[a].substring(1),
            );
            if (d.oldRanges.isNotEmpty) intraline[base + r] = d.oldRanges;
            if (d.newRanges.isNotEmpty) intraline[base + a] = d.newRanges;
          }
        }
      } else {
        i++;
      }
    }
    base += n;
  }

  return [
    for (var b = 0; b < total; b++)
      DiffLineHighlight(
        kinds[b],
        _runsFor(side[b], imageIndex[b], contents[b], postDoc, preDoc),
        intraline[b],
      ),
  ];
}

List<ScopedRun>? _runsFor(
  int side,
  int idx,
  String content,
  HighlightedLines? postDoc,
  HighlightedLines? preDoc,
) {
  final doc = side == 0 ? postDoc : (side == 1 ? preDoc : null);
  if (doc == null || idx < 0 || idx >= doc.lines.length) return null;
  final line = doc.lines[idx];
  // Defend against any image-reconstruction drift: only trust runs whose backing
  // text is exactly this row's content.
  if (line.text != content) return null;
  return [
    for (var k = 0; k < line.runCount; k++)
      ScopedRun(
        line.runStarts[k],
        line.runStarts[k + 1],
        line.runScopeIds[k] < 0 ? null : doc.scopes[line.runScopeIds[k]],
      ),
  ];
}

/// A deeper add/remove wash marking the changed characters within a modified
/// line, drawn behind the syntax colours. Null for unchanged/other kinds.
Color? _emphasisBackground(DiffLineKind kind) => switch (kind) {
  DiffLineKind.add => MacosColors.systemGreenColor.withValues(alpha: 0.30),
  DiffLineKind.remove => MacosColors.systemRedColor.withValues(alpha: 0.30),
  DiffLineKind.context ||
  DiffLineKind.noNewline ||
  DiffLineKind.other => null,
};

/// Builds the [TextSpan] for one diff body line: the leading marker in the
/// kind's colour, then the content — syntax-coloured when [h] carries runs
/// (unscoped text and the whole line, when there are no runs, fall back to the
/// kind colour so an unsupported file looks exactly as before), with a deeper
/// wash on the intra-line changed ranges.
///
/// Keeps the marker glyph in the span so a copied selection still round-trips
/// through `git apply`, and returns a single multi-run `TextSpan` so it drops
/// straight into the existing `SelectionArea` (cross-line selection unaffected —
/// `CodeView` renders the same way).
TextSpan diffLineSpan(
  String rawLine,
  DiffLineHighlight? h,
  TextStyle base,
  Color defaultColor,
  CodeTheme theme,
) {
  if (rawLine.isEmpty) return TextSpan(text: rawLine, style: base);
  final kind = h?.kind ?? diffLineKind(rawLine);
  final kindColor = diffKindColor(kind, defaultColor);
  final marker = rawLine.substring(0, 1);
  final content = rawLine.substring(1);
  final markerSpan = TextSpan(text: marker, style: base.copyWith(color: kindColor));
  if (content.isEmpty) return TextSpan(style: base, children: [markerSpan]);

  final runs = h?.runs;
  final intraline = h?.intraline ?? const <IntralineRange>[];
  final emphasis = _emphasisBackground(kind);
  // With syntax runs, unscoped text is the neutral body colour (add/remove is
  // carried by the marker + row band); without runs, keep the classic all-green/
  // all-red content colour.
  final contentColor = runs == null ? kindColor : defaultColor;

  return TextSpan(
    style: base,
    children: [
      markerSpan,
      ..._contentSpans(content, runs, base, contentColor, theme, intraline, emphasis),
    ],
  );
}

List<InlineSpan> _contentSpans(
  String content,
  List<ScopedRun>? runs,
  TextStyle base,
  Color contentColor,
  CodeTheme theme,
  List<IntralineRange> intraline,
  Color? emphasis,
) {
  final len = content.length;
  // Segment boundaries: run edges and intra-line edges, clamped and deduped.
  final cuts = <int>{0, len};
  if (runs != null) {
    for (final r in runs) {
      cuts.add(r.start.clamp(0, len));
      cuts.add(r.end.clamp(0, len));
    }
  }
  for (final r in intraline) {
    cuts.add(r.start.clamp(0, len));
    cuts.add(r.end.clamp(0, len));
  }
  final points = cuts.toList()..sort();

  final spans = <InlineSpan>[];
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (a >= b) continue;
    String? scope;
    if (runs != null) {
      for (final r in runs) {
        if (r.start <= a && a < r.end) {
          scope = r.scope;
          break;
        }
      }
    }
    var style = base.copyWith(color: contentColor);
    if (scope != null) {
      final s = theme.styles[scope];
      if (s != null) style = style.merge(s);
    }
    if (emphasis != null && intraline.any((r) => r.start <= a && a < r.end)) {
      style = style.copyWith(backgroundColor: emphasis);
    }
    spans.add(TextSpan(text: content.substring(a, b), style: style));
  }
  return spans;
}
