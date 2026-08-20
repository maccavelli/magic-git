import 'package:flutter/widgets.dart';

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

/// Per-line render data for one diff-hunk body line: its [kind] and the
/// syntax-highlighted content [runs] (null when the file's language is
/// unsupported/oversized — the content is then drawn in the kind's colour, as
/// before).
///
/// All fields are isolate-sendable (ints/strings/enums), so this is produced in
/// the same parse pass that already moves off the UI isolate for huge diffs.
class DiffLineHighlight {
  final DiffLineKind kind;
  final List<ScopedRun>? runs;
  const DiffLineHighlight(this.kind, this.runs);
}

/// Above this many hunk-body lines, syntax highlighting is skipped (the content
/// still renders, coloured by kind). Mirrors the diff-parse isolate threshold's
/// intent: a regenerated lockfile or minified bundle shouldn't pay the
/// highlighter.
const int _highlightMaxLines = 6000;

/// Computes per-body-line [DiffLineHighlight]s for [file], one per hunk body
/// line in the order the hunks are flattened (all of hunk 0, then hunk 1, …) —
/// exactly the order [HunkDiffView] builds its line items.
///
/// Syntax highlighting reconstructs the pre- and post-images once and highlights
/// each whole (so multi-line grammar state — open strings, block comments — is
/// correct) then maps runs back to rows; it is gated by [enableHighlight] and
/// language support.
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
  final languageId = viewerFileTypeFor(
    file.newPath ?? file.oldPath ?? '',
  ).languageId;
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

  return [
    for (var b = 0; b < total; b++)
      DiffLineHighlight(
        kinds[b],
        _runsFor(side[b], imageIndex[b], contents[b], postDoc, preDoc),
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
  return _runsOfLine(line, doc.scopes);
}

List<ScopedRun> _runsOfLine(HighlightedLine line, List<String?> scopes) => [
  for (var k = 0; k < line.runCount; k++)
    ScopedRun(
      line.runStarts[k],
      line.runStarts[k + 1],
      line.runScopeIds[k] < 0 ? null : scopes[line.runScopeIds[k]],
    ),
];

/// The highlight.js language id for [file] (from its path), or null when the
/// extension isn't recognised.
String? diffLanguageId(DiffFile file) =>
    viewerFileTypeFor(file.newPath ?? file.oldPath ?? '').languageId;

/// Highlights an image — the ordered line contents of one side of a diff — as
/// [languageId], returning per line its syntax [ScopedRun]s (or null when
/// highlighting is disabled, the language is unsupported, or a line's backing
/// text drifts from the input). The whole image is highlighted in one call so
/// multi-line grammar state (open strings, block comments) stays correct, then
/// runs are mapped back per line. Used by the split renderer, which highlights
/// its old (pre-image) and new (post-image) columns independently.
List<List<ScopedRun>?> highlightImageRuns(
  List<String> contents,
  String? languageId, {
  bool enable = true,
}) {
  if (!enable ||
      contents.isEmpty ||
      languageId == null ||
      !isLanguageSupported(languageId)) {
    return List<List<ScopedRun>?>.filled(contents.length, null);
  }
  final doc = highlightDoc(contents.join('\n'), languageId);
  return [
    for (var i = 0; i < contents.length; i++)
      (i < doc.lines.length && doc.lines[i].text == contents[i])
          ? _runsOfLine(doc.lines[i], doc.scopes)
          : null,
  ];
}

/// Highlights the content lines of a **raw multi-file unified diff** (the flat
/// [DiffView]'s model), returning per source line its syntax [ScopedRun]s or
/// null (headers, `\ No newline`, and — when highlighting is skipped — every
/// line). Each file block (delimited by `diff --git`/`--cc`/`--combined`) is
/// highlighted once against the language of its `+++`/`---` path; a diff with
/// no file headers (already-split fallback text) is left plain.
List<List<ScopedRun>?> highlightRawDiffLines(List<String> lines) {
  final runs = List<List<ScopedRun>?>.filled(lines.length, null);
  if (lines.length > _highlightMaxLines) return runs;
  final starts = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startsWith('diff --git ') ||
          lines[i].startsWith('diff --cc ') ||
          lines[i].startsWith('diff --combined '))
        i,
  ];
  if (starts.isEmpty) return runs;

  for (var f = 0; f < starts.length; f++) {
    final from = starts[f];
    final to = f + 1 < starts.length ? starts[f + 1] : lines.length;
    final lang = _diffBlockLanguage(lines, from, to);
    final indices = <int>[];
    final contents = <String>[];
    for (var i = from; i < to; i++) {
      final l = lines[i];
      if (_isDiffContentLine(l)) {
        indices.add(i);
        contents.add(l.isEmpty ? '' : l.substring(1));
      }
    }
    final blockRuns = highlightImageRuns(contents, lang);
    for (var k = 0; k < indices.length; k++) {
      runs[indices[k]] = blockRuns[k];
    }
  }
  return runs;
}

/// The language of the file block `[from, to)`, from its `+++ b/path` (or
/// `--- a/path` when the new side is `/dev/null`, i.e. a deletion).
String? _diffBlockLanguage(List<String> lines, int from, int to) {
  String? path;
  for (var i = from; i < to; i++) {
    final l = lines[i];
    if (l.startsWith('+++ ')) {
      final p = _diffHeaderPath(l.substring(4));
      if (p != null) {
        path = p;
        break;
      }
    } else if (l.startsWith('--- ') && path == null) {
      path = _diffHeaderPath(l.substring(4));
    }
  }
  return path == null ? null : viewerFileTypeFor(path).languageId;
}

/// Extracts a usable path from a `---`/`+++` header value: drops any trailing
/// tab metadata and the `a/`/`b/` prefix; null for `/dev/null`.
String? _diffHeaderPath(String value) {
  var p = value;
  final tab = p.indexOf('\t');
  if (tab >= 0) p = p.substring(0, tab);
  if (p == '/dev/null') return null;
  if (p.startsWith('a/') || p.startsWith('b/')) p = p.substring(2);
  return p.isEmpty ? null : p;
}

/// A hunk body line (add/remove/context) — not a header, hunk marker, or
/// no-newline note.
bool _isDiffContentLine(String l) {
  if (l.isEmpty) return false;
  switch (l[0]) {
    case '+':
      return !l.startsWith('+++');
    case '-':
      return !l.startsWith('---');
    case ' ':
      return true;
    default:
      return false; // '@@', '\', 'diff', 'index', 'new file', …
  }
}

/// Builds the [TextSpan] for one diff body line: the leading marker in the
/// kind's colour, then the content — syntax-coloured when [h] carries runs
/// (unscoped text and the whole line, when there are no runs, fall back to the
/// kind colour so an unsupported file looks exactly as before).
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
  final markerSpan = TextSpan(
    text: marker,
    style: base.copyWith(color: kindColor),
  );
  if (content.isEmpty) return TextSpan(style: base, children: [markerSpan]);

  final runs = h?.runs;
  // Unscoped text keeps the kind's colour so the red/green sense is preserved
  // (an added line still reads green); recognised tokens tint over it. This is
  // also what keeps unified and split agreeing on what green means.
  final contentColor = kindColor;

  return TextSpan(
    style: base,
    children: [
      markerSpan,
      ..._contentSpans(content, runs, base, contentColor, theme),
    ],
  );
}

/// Builds the [TextSpan] for one **split-view cell** — content only, no marker
/// (side-by-side rows carry the kind in their column, not a leading `+`/`-`).
/// Syntax-colours the content (unscoped text falls back to the kind colour when
/// there are no runs, so an unsupported file looks unchanged). [kind] is
/// `remove` for the left column, `add` for the right, `context` for both sides
/// of an unchanged row.
TextSpan diffCellSpan(
  String content,
  List<ScopedRun>? runs,
  DiffLineKind kind,
  TextStyle base,
  Color defaultColor,
  CodeTheme theme,
) {
  final kindColor = diffKindColor(kind, defaultColor);
  // Unscoped text keeps the kind's colour (green add / red remove / neutral
  // context) so the split view agrees with unified on what green means;
  // recognised tokens tint over it.
  final contentColor = kindColor;
  return TextSpan(
    style: base,
    children: _contentSpans(content, runs, base, contentColor, theme),
  );
}

List<InlineSpan> _contentSpans(
  String content,
  List<ScopedRun>? runs,
  TextStyle base,
  Color contentColor,
  CodeTheme theme,
) {
  final len = content.length;
  // Segment boundaries: run edges, clamped and deduped.
  final cuts = <int>{0, len};
  if (runs != null) {
    for (final r in runs) {
      cuts.add(r.start.clamp(0, len));
      cuts.add(r.end.clamp(0, len));
    }
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
    spans.add(TextSpan(text: content.substring(a, b), style: style));
  }
  return spans;
}
