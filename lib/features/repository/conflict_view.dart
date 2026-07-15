import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../common/diff_view.dart';

/// Which region of a conflict block a line falls in, so "ours", "theirs" (and,
/// for `diff3`/`zdiff3` style conflicts, the common "ancestor") can be colored
/// distinctly. Classification only depends on the sequential scan of marker
/// lines, so it's precomputed once per [ConflictView.content] rather than
/// re-derived on every rebuild.
enum _LineRegion {
  oursMarker,
  ancestorMarker,
  separator,
  theirsMarker,
  insideOurs,
  insideAncestor,
  insideTheirs,
  normal,
}

class _ConflictLine {
  final String text;
  final _LineRegion region;
  const _ConflictLine(this.text, this.region);
}

/// Heuristic for "this conflicted file is binary, not text" from a string
/// that has already been UTF-8 decoded upstream with `allowMalformed: true`
/// (see the SSH layer) — so genuinely binary content shows up here as a wall
/// of U+FFFD replacement characters and stray control bytes rather than as
/// decode errors we could catch directly.
///
/// Deliberately conservative: a stray NUL byte is an unambiguous binary
/// signal (legitimate text — including mis-decoded non-English scripts —
/// essentially never contains one), but replacement characters/control bytes
/// only trip the heuristic once they clear a density threshold over a
/// meaningful sample, so a handful of mojibake characters in otherwise
/// normal text doesn't get misclassified as binary.
bool _looksBinary(String content) {
  if (content.isEmpty) return false;
  var nulCount = 0;
  var suspiciousCount = 0;
  var total = 0;
  for (final rune in content.runes) {
    total++;
    if (rune == 0x00) {
      nulCount++;
    } else if (rune == 0xFFFD ||
        (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D)) {
      suspiciousCount++;
    }
  }
  if (nulCount > 0) return true;
  // Too short a sample to trust a density-based judgment.
  if (total < 32) return false;
  return suspiciousCount / total > 0.10;
}

/// Scans [content] once, classifying each line the same way the original
/// single-pass renderer did: `region` tracks whether we're inside "ours"
/// (between `<<<<<<<` and `=======`), the `diff3`/`zdiff3` common ancestor
/// section (between `|||||||` and `=======`), or "theirs" (between
/// `=======` and `>>>>>>>`).
List<_ConflictLine> _classifyLines(String content) {
  final lines = <_ConflictLine>[];
  // 0 = normal, 1 = inside "ours", 2 = inside ancestor, 3 = inside "theirs".
  var region = 0;
  for (final line in const LineSplitter().convert(content)) {
    _LineRegion kind;
    if (line.startsWith('<<<<<<<')) {
      region = 1;
      kind = _LineRegion.oursMarker;
    } else if (line.startsWith('|||||||') && region == 1) {
      region = 2;
      kind = _LineRegion.ancestorMarker;
    } else if (line.startsWith('=======') && region != 0) {
      region = 3;
      kind = _LineRegion.separator;
    } else if (line.startsWith('>>>>>>>')) {
      kind = _LineRegion.theirsMarker;
      region = 0;
    } else if (region == 1) {
      kind = _LineRegion.insideOurs;
    } else if (region == 2) {
      kind = _LineRegion.insideAncestor;
    } else if (region == 3) {
      kind = _LineRegion.insideTheirs;
    } else {
      kind = _LineRegion.normal;
    }
    lines.add(_ConflictLine(line, kind));
  }
  return lines;
}

/// Renders a conflicted file, coloring the `<<<<<<<`/`|||||||`/`=======`/
/// `>>>>>>>` regions so "ours", the `diff3`/`zdiff3` ancestor, and "theirs"
/// are all visually distinct.
///
/// Uses the shared [DiffPan] so long lines pan as one unit (the same model as
/// every other diff surface) instead of each line owning its own horizontal
/// scroller — that older shape made the conflict "come apart" under the cursor
/// and left text sitting outside the visual margins of the pane.
class ConflictView extends StatefulWidget {
  final String content;

  const ConflictView({super.key, required this.content});

  @override
  State<ConflictView> createState() => _ConflictViewState();
}

class _ConflictViewState extends State<ConflictView> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  List<_ConflictLine> _lines = const [];
  double _maxLineWidth = 0;
  bool _isBinary = false;

  @override
  void initState() {
    super.initState();
    _reload(widget.content);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ConflictView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same object identity, not just equal content, is the common case — see
    // the equivalent memoization in HunkDiffView/SplitDiffView.
    if (oldWidget.content != widget.content) {
      _reload(widget.content);
    }
  }

  void _reload(String content) {
    _isBinary = _looksBinary(content);
    _lines = _isBinary ? const [] : _classifyLines(content);
    _maxLineWidth = _isBinary
        ? 0
        : measureDiffWidth(_lines.map((l) => l.text));
  }

  @override
  Widget build(BuildContext context) {
    if (_isBinary) {
      return Center(
        child: Text(
          'Binary file conflict — resolve via the command line',
          style: MacosTheme.of(
            context,
          ).typography.caption1.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

    // SelectionArea + plain Text so a resolution snippet spanning markers can
    // be drag-copied — per-line SelectableText couldn't span lines.
    return DiffPan(
      vertical: _vertical,
      horizontal: _horizontal,
      maxLineWidth: _maxLineWidth,
      builder: (context, contentWidth, _) {
        return SelectionArea(
          child: ListView.builder(
            controller: _vertical,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemExtent: kDiffLineExtent,
            itemCount: _lines.length,
            itemBuilder: (context, i) {
              final line = _lines[i];
              final (color, background) = _colorsFor(line.region, defaultColor);
              return Container(
                width: contentWidth,
                color: background,
                padding: const EdgeInsets.symmetric(horizontal: kDiffHPad),
                alignment: Alignment.centerLeft,
                child: Text(
                  line.text,
                  maxLines: 1,
                  softWrap: false,
                  strutStyle: kDiffStrut,
                  style: kDiffMono.copyWith(color: color),
                ),
              );
            },
          ),
        );
      },
    );
  }

  (Color, Color?) _colorsFor(_LineRegion region, Color defaultColor) {
    switch (region) {
      case _LineRegion.oursMarker:
        return (
          MacosColors.systemBlueColor,
          MacosColors.systemBlueColor.withValues(alpha: 0.18),
        );
      case _LineRegion.ancestorMarker:
        return (
          MacosColors.systemOrangeColor,
          MacosColors.systemOrangeColor.withValues(alpha: 0.18),
        );
      case _LineRegion.separator:
        return (MacosColors.systemGrayColor, null);
      case _LineRegion.theirsMarker:
        return (
          MacosColors.systemGreenColor,
          MacosColors.systemGreenColor.withValues(alpha: 0.18),
        );
      case _LineRegion.insideOurs:
        return (
          defaultColor,
          MacosColors.systemBlueColor.withValues(alpha: 0.10),
        );
      case _LineRegion.insideAncestor:
        return (
          defaultColor,
          MacosColors.systemOrangeColor.withValues(alpha: 0.10),
        );
      case _LineRegion.insideTheirs:
        return (
          defaultColor,
          MacosColors.systemGreenColor.withValues(alpha: 0.10),
        );
      case _LineRegion.normal:
        return (defaultColor, null);
    }
  }
}
