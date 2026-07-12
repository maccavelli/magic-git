import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';

/// Monospace text style shared by the diff views.
const kDiffMono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
  fontSize: 12,
  height: 1.35,
);

/// The exact rendered height of one diff line — [kDiffMono]'s fontSize × its
/// line-height. Every line in the flat [DiffView] is a single, non-wrapping
/// monospace line, so pinning this as a uniform `itemExtent` lets the list skip
/// per-line layout for its scroll math (O(1) jump-scroll on large patches)
/// without changing the layout, since it equals each line's intrinsic height.
const double kDiffLineExtent = 12 * 1.35; // = 16.2

/// Per-line syntax color for a unified-diff line, shared by [DiffView] and the
/// hunk-staging view.
///
/// Header/hunk-header lines (`diff --git`, `index`, `@@ …`, etc.) are a
/// concern specific to rendering a *flat* diff — [DiffLineKind] intentionally
/// only classifies lines *within* an already-parsed hunk body, so those are
/// still handled here directly. For the overlap (add/remove/context) this
/// defers to [diffLineKind] rather than re-testing the leading character
/// independently, so there's exactly one place that decides what `+`/`-`/` `
/// mean.
Color diffLineColor(String line, Color defaultColor) {
  if (line.startsWith('@@')) return MacosColors.systemTealColor;
  if (line.startsWith('diff ') ||
      line.startsWith('index ') ||
      line.startsWith('+++ ') ||
      line.startsWith('--- ') ||
      line.startsWith('new file') ||
      line.startsWith('deleted file') ||
      line.startsWith('rename ') ||
      line.startsWith('similarity ')) {
    return MacosColors.systemGrayColor;
  }
  return switch (diffLineKind(line)) {
    DiffLineKind.add => MacosColors.systemGreenColor,
    DiffLineKind.remove => MacosColors.systemRedColor,
    DiffLineKind.context ||
    DiffLineKind.noNewline ||
    DiffLineKind.other => defaultColor,
  };
}

/// Renders a raw unified diff (from `git diff` / `git show`) with per-line
/// syntax coloring in a monospace font. Uses [ListView.builder] so large patches
/// stay responsive.
///
/// [wrap] chooses the line-length behavior:
///  * false (default): every line stays on one line and the whole diff shares
///    ONE horizontal scrollbar along the bottom, so you can scroll all lines
///    together to reach their ends. Uniform row height keeps the fixed
///    [kDiffLineExtent] item extent (O(1) jump-scroll on large patches).
///  * true: long lines wrap to the viewport width (variable row heights, no
///    horizontal scroll).
class DiffView extends StatefulWidget {
  final String diff;
  final bool wrap;

  const DiffView({super.key, required this.diff, this.wrap = false});

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  static const _mono = kDiffMono;
  static const double _hPad = 12;

  // Separate controllers so the two nested scrollbars (vertical list, shared
  // horizontal pan) each drive an unambiguous axis.
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  late List<String> _lines = const LineSplitter().convert(widget.diff);
  late int _maxLineChars = _computeMaxChars(_lines);

  static int _computeMaxChars(List<String> lines) {
    var longest = 0;
    for (final line in lines) {
      if (line.length > longest) longest = line.length;
    }
    return longest;
  }

  /// The advance width of one [kDiffMono] glyph, measured once. The font is
  /// monospace, so char count × this is an exact line width — no need to lay
  /// out every line to size the shared horizontal extent.
  static double? _charWidth;
  static double _monoCharWidth() {
    return _charWidth ??= (TextPainter(
      text: const TextSpan(text: '00000000000000000000', style: kDiffMono),
      textDirection: TextDirection.ltr,
    )..layout()).width /
        20;
  }

  @override
  void didUpdateWidget(DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Skip re-splitting when nothing actually changed — sibling diff views
    // (HunkDiffView/SplitDiffView) already do the equivalent for their own
    // parse step, and diff providers commonly hand back the same content
    // across otherwise-unrelated rebuilds (a theme change, a parent resize).
    if (oldWidget.diff != widget.diff) {
      _lines = const LineSplitter().convert(widget.diff);
      _maxLineChars = _computeMaxChars(_lines);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.diff.trim().isEmpty) {
      return Center(
        child: Text(
          'No changes',
          style: MacosTheme.of(context).typography.body,
        ),
      );
    }

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

    return widget.wrap
        ? _buildWrapped(defaultColor)
        : _buildUnwrapped(defaultColor);
  }

  // One SelectionArea over plain Text lines (not per-line SelectableText):
  // selection state doesn't span separate SelectableText widgets, so the old
  // shape made it impossible to drag-copy a multi-line hunk. This is the same
  // pattern the blame sheet uses, and each row is lighter too.

  Widget _buildWrapped(Color defaultColor) {
    return Scrollbar(
      controller: _vertical,
      child: SelectionArea(
        child: ListView.builder(
          controller: _vertical,
          padding: const EdgeInsets.symmetric(vertical: 12),
          // Wrapped lines have variable height, so no fixed itemExtent — the
          // builder still lazily measures only the visible rows.
          itemCount: _lines.length,
          itemBuilder: (context, index) {
            final line = _lines[index];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: _hPad),
              child: Text(
                line,
                style: _mono.copyWith(color: diffLineColor(line, defaultColor)),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildUnwrapped(Color defaultColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final lineWidth = _maxLineChars * _monoCharWidth() + _hPad * 2;
        final overflows = lineWidth > constraints.maxWidth;
        // The inner list is as wide as the widest line (never narrower than the
        // viewport), so the single horizontal scroll below reveals every line's
        // end in lockstep.
        final contentWidth = math.max(constraints.maxWidth, lineWidth);
        return Scrollbar(
          controller: _vertical,
          // The vertical list sits one viewport deeper than the horizontal
          // scroll, so its notifications arrive at depth 1 here; the default
          // depth-0 predicate would otherwise track the horizontal axis.
          notificationPredicate: (notification) => notification.depth == 1,
          child: Scrollbar(
            controller: _horizontal,
            // Keep the bottom bar visible whenever lines run past the edge, so
            // the "there's more to the right" affordance is never hidden.
            thumbVisibility: overflows,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                height: constraints.maxHeight,
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _vertical,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemExtent: kDiffLineExtent,
                    itemCount: _lines.length,
                    itemBuilder: (context, index) {
                      final line = _lines[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: _hPad),
                        child: Text(
                          line,
                          maxLines: 1,
                          softWrap: false,
                          style: _mono.copyWith(
                            color: diffLineColor(line, defaultColor),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
