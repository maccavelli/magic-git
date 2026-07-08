import 'dart:convert';
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
class DiffView extends StatefulWidget {
  final String diff;

  const DiffView({super.key, required this.diff});

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  static const _mono = kDiffMono;

  late List<String> _lines = const LineSplitter().convert(widget.diff);

  @override
  void didUpdateWidget(DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Skip re-splitting when nothing actually changed — sibling diff views
    // (HunkDiffView/SplitDiffView) already do the equivalent for their own
    // parse step, and diff providers commonly hand back the same content
    // across otherwise-unrelated rebuilds (a theme change, a parent resize).
    if (oldWidget.diff != widget.diff) {
      _lines = const LineSplitter().convert(widget.diff);
    }
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

    return Scrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemExtent: kDiffLineExtent,
        itemCount: _lines.length,
        itemBuilder: (context, index) {
          final line = _lines[index];
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              line,
              style: _mono.copyWith(color: diffLineColor(line, defaultColor)),
            ),
          );
        },
      ),
    );
  }
}
