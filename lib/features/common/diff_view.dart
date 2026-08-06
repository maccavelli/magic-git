import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import '../../core/utils/display_error.dart';
import '../viewer/code_view.dart' show CodeTheme, codeThemeFor;
import 'diff_highlight.dart';

/// Shared vocabulary for every diff surface in the app.
///
/// Four widgets render diffs — [DiffView] (flat, read-only), `HunkDiffView`
/// (unified, per-hunk staging), `SplitDiffView` (side-by-side) and
/// `CommitPatchView` (a commit's patch, with context expanders). They had drifted
/// into disagreeing about things a user reads as one feature: what green means,
/// whether a long line pans the whole diff or only itself, whether a huge patch
/// is parsed off the UI thread, and what a pane looks like while it loads. Each
/// of those now has exactly one definition, and it lives here.

/// Monospace text style shared by the diff views.
const kDiffMono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
  fontSize: 12,
  height: 1.35,
);

/// Locks every mono line to exactly [kDiffLineExtent].
///
/// Fixed-`itemExtent` lists (flat [DiffView], [CommitPatchView]) size each
/// slot to that height. Without a forced strut, Menlo metrics under a
/// [SelectionArea] can measure a hair taller and the glyph run clips against
/// the slot — the "text pushed out of the margins" look. Every diff [Text]
/// should pass this so measured height and slot height stay one number.
const kDiffStrut = StrutStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
  fontSize: 12,
  height: 1.35,
  forceStrutHeight: true,
  leadingDistribution: TextLeadingDistribution.even,
);

/// The exact rendered height of one diff line — [kDiffMono]'s fontSize × its
/// line-height, enforced by [kDiffStrut]. Uniform `itemExtent` lets the list
/// skip per-line layout for scroll math (O(1) jump-scroll on large patches).
const double kDiffLineExtent = 12 * 1.35; // = 16.2

/// Horizontal inset on every diff line / cell, in every renderer.
const double kDiffHPad = 12;

/// Width of the vertical rule between split-diff columns.
const double kDiffSplitSeparator = 1;

/// Soft fill behind an addition or removal — same alpha the split view uses on
/// its cells, so unified and side-by-side read as one palette.
Color? diffKindBackground(DiffLineKind kind) => switch (kind) {
  DiffLineKind.add => MacosColors.systemGreenColor.withValues(alpha: 0.12),
  DiffLineKind.remove => MacosColors.systemRedColor.withValues(alpha: 0.12),
  DiffLineKind.context || DiffLineKind.noNewline || DiffLineKind.other => null,
};

/// Soft fill for a *raw* unified-diff line (still carrying its `+`/`-` marker).
/// Header and hunk-header lines stay clear so the band only marks the change.
Color? diffLineBackground(String line) {
  if (line.startsWith('@@') ||
      line.startsWith('diff ') ||
      line.startsWith('index ') ||
      line.startsWith('+++ ') ||
      line.startsWith('--- ') ||
      line.startsWith('new file') ||
      line.startsWith('deleted file') ||
      line.startsWith('rename ') ||
      line.startsWith('similarity ')) {
    return null;
  }
  return diffKindBackground(diffLineKind(line));
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/// What a diff line's *kind* looks like. The single source of truth for the
/// palette: an addition is this green and a removal is this red everywhere.
///
/// Kept separate from [diffLineColor] because not every renderer still has the
/// leading `+`/`-` to look at — the side-by-side view strips the marker and
/// derives the kind from which column a line landed in. That is a different
/// question ("what kind is this row?") with the same answer ("so it is this
/// colour"), and routing both through here is what stops the two from drifting.
Color diffKindColor(DiffLineKind kind, Color defaultColor) => switch (kind) {
  DiffLineKind.add => MacosColors.systemGreenColor,
  DiffLineKind.remove => MacosColors.systemRedColor,
  DiffLineKind.context ||
  DiffLineKind.noNewline ||
  DiffLineKind.other => defaultColor,
};

/// Per-line syntax colour for a *raw* unified-diff line — one that still carries
/// its leading marker.
///
/// Header/hunk-header lines (`diff --git`, `index`, `@@ …`) are a concern
/// specific to rendering a flat diff — [DiffLineKind] intentionally only
/// classifies lines *within* an already-parsed hunk body — so those are handled
/// here. Everything else defers to [diffLineKind] + [diffKindColor], so there is
/// exactly one place that decides what `+`/`-`/` ` mean and exactly one that
/// decides what they look like.
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
  return diffKindColor(diffLineKind(line), defaultColor);
}

/// The teal a `@@ … @@` hunk header is drawn in, wherever one is rendered as a
/// row of its own rather than as a line of raw diff text.
const Color kDiffHunkHeaderColor = MacosColors.systemTealColor;

// ---------------------------------------------------------------------------
// Parsing a patch into rows, off the UI thread when it is big
// ---------------------------------------------------------------------------

/// Above this many lines, a patch is parsed on a background isolate.
///
/// Below it, parsing runs inline: an isolate spawn's own overhead would dwarf
/// the work for the overwhelming majority of diffs, and going async would cost
/// the common case a frame of spinner for nothing. Only a genuinely huge patch —
/// a regenerated lockfile, a minified bundle, a vendored dependency bump; tens of
/// thousands of lines — crosses this and moves off thread so selecting it cannot
/// jank a frame.
const int kDiffIsolateLineThreshold = 20000;

int diffLineCount(String diff) => '\n'.allMatches(diff).length + 1;

/// Turns raw patch text into a renderer's row model, on a background isolate
/// when the patch is large enough that parsing it inline would drop frames.
///
/// [parse] is handed to `Isolate.run`, so it **must** be a top-level or static
/// function — a closure over widget state is not sendable.
///
/// Every renderer that parses a patch owns one of these. Before, three of them
/// hand-rolled the same threshold, the same line count and the same
/// supersede-by-request-id dance — and two of them hand-rolled it with no error
/// arm at all, so a parse that failed (or an isolate that never spawned, which is
/// likeliest on exactly the giant patches that take this path) left the pane's
/// spinner up with nothing left alive to clear it.
class DiffParser<T> {
  DiffParser(this._parse);

  final T Function(String) _parse;

  /// Bumped per parse, so a result superseded by a newer one is dropped rather
  /// than clobbering state the widget has already moved past.
  int _requestId = 0;

  /// Parses [diff], superseding any parse already in flight.
  ///
  /// Returns the result **synchronously** when it ran inline (the common case,
  /// and why this isn't just a `Future`). Returns null when it went off-thread:
  /// exactly one of [onDone] / [onFailed] then runs later, unless a newer parse
  /// supersedes it first, in which case neither does.
  ///
  /// The result is wrapped in a record rather than returned bare, so "ran
  /// inline" and "went off-thread" stay distinguishable when `T` is itself
  /// nullable — `null` is a perfectly ordinary inline result (a binary diff has
  /// no rows), and conflating the two made a binary file render as a spinner.
  ///
  /// [onFailed] is not optional and not decoration — it is the difference
  /// between a pane that degrades and a pane that spins forever.
  ({T result})? parse(
    String diff, {
    required void Function(T result) onDone,
    required void Function() onFailed,
  }) {
    final id = ++_requestId;
    if (diffLineCount(diff) <= kDiffIsolateLineThreshold) {
      return (result: _parse(diff));
    }

    Isolate.run(() => _parse(diff)).then(
      (result) {
        if (id == _requestId) onDone(result);
      },
      onError: (Object _, StackTrace _) {
        if (id == _requestId) onFailed();
      },
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// The exact rendered width of the widest line in [lines], which is what sizes a
/// diff's shared horizontal scroll extent.
///
/// Only the single longest line (by character count — the font is monospace) is
/// actually laid out, so this stays cheap on a huge patch; measuring the real
/// glyph run rather than estimating char-count × advance means the extent is
/// never a hair short, so a long line's tail always scrolls fully into view.
///
/// The monospace assumption is where this is approximate: a line of CJK or a line
/// full of tabs renders wider than its character count suggests, so a *shorter*
/// line could in principle out-measure the one picked here. It has never bitten,
/// and the alternative — laying out every line — is not worth paying on every
/// patch to fix it.
double measureDiffWidth(Iterable<String> lines) {
  var longest = '';
  for (final line in lines) {
    if (line.length > longest.length) longest = line;
  }
  if (longest.isEmpty) return 0;
  return (TextPainter(
    text: TextSpan(text: longest, style: kDiffMono),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout()).width;
}

/// The scroll shape every unwrapped diff shares: a vertical list, and **one**
/// horizontal pan across the whole diff.
///
/// One pan, not one per line. The hunk and split views used to give every line
/// (and every split cell) its own [SingleChildScrollView], so scrolling
/// horizontally moved that one line and left the rest behind — the diff came
/// apart, and there was no way to read the ends of a run of long lines together.
/// Here the inner list is as wide as the widest line and the whole thing pans as
/// a unit, so every line's tail arrives in lockstep.
///
/// [builder] is given the width its rows must fill — so a row's background band
/// spans the whole diff rather than stopping at the viewport edge — and the
/// viewport's own width, so a row that is a *control* rather than text can hold
/// still with [DiffPinnedRow].
class DiffPan extends StatelessWidget {
  const DiffPan({
    super.key,
    required this.vertical,
    required this.horizontal,
    required this.maxLineWidth,
    required this.builder,
  });

  final ScrollController vertical;
  final ScrollController horizontal;

  /// Widest rendered line, *excluding* the [kDiffHPad] on either side of it.
  final double maxLineWidth;

  final Widget Function(
    BuildContext context,
    double contentWidth,
    double viewportWidth,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final lineWidth = maxLineWidth + kDiffHPad * 2;
        final overflows = lineWidth > constraints.maxWidth;
        final contentWidth = math.max(constraints.maxWidth, lineWidth);
        return Scrollbar(
          controller: vertical,
          // The vertical list sits one viewport deeper than the horizontal
          // scroll, so its notifications arrive at depth 1 here; the default
          // depth-0 predicate would otherwise track the horizontal axis.
          notificationPredicate: (notification) => notification.depth == 1,
          child: Scrollbar(
            controller: horizontal,
            // Keep the bottom bar visible whenever lines run past the edge, so
            // the "there's more to the right" affordance is never hidden.
            thumbVisibility: overflows,
            // Clip so a panning [DiffPinnedRow] (and any selection glow) cannot
            // paint past the pane edge — the residual of the translate-pin
            // approach that otherwise looks like text leaving the margins.
            child: ClipRect(
              child: SingleChildScrollView(
                controller: horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth,
                  height: constraints.maxHeight,
                  child: builder(context, contentWidth, constraints.maxWidth),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A row inside a [DiffPan] that stays put in the viewport while the diff pans
/// horizontally beneath it.
///
/// For rows that are **controls**, not text: a hunk header carrying Stage /
/// Unstage / Discard, or a `⋯` gap expander. Panning right to read the end of a
/// long line would otherwise carry those buttons off the screen with it, leaving
/// the diff's own actions unreachable exactly when the diff is widest. Text rows
/// pan; controls hold still.
class DiffPinnedRow extends StatelessWidget {
  const DiffPinnedRow({
    super.key,
    required this.horizontal,
    required this.viewportWidth,
    required this.child,
  });

  final ScrollController horizontal;
  final double viewportWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Clip to the viewport width so a translate that overshoots during a pan
    // (or a child that paints outside its box) never draws into the panned
    // gutter beside the control.
    return ClipRect(
      child: AnimatedBuilder(
        animation: horizontal,
        builder: (context, child) {
          // Shift by exactly the pan, so the row lands back where the viewport is.
          final dx = horizontal.hasClients ? horizontal.offset : 0.0;
          return Transform.translate(
            offset: Offset(dx, 0),
            child: SizedBox(width: viewportWidth, child: child),
          );
        },
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

/// The spinner every diff surface shows while its patch is being fetched.
class DiffPending extends StatelessWidget {
  const DiffPending({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: ProgressCircle());
}

/// The message every diff surface shows when its patch could not be fetched.
/// One definition, so a failure looks the same whether it happened in the
/// Repository panel, a pop-out, History, a stash preview or the recovery sheet.
class DiffFailure extends StatelessWidget {
  const DiffFailure(this.error, {super.key});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        displayError(error),
        style: MacosTheme.of(
          context,
        ).typography.body.copyWith(color: MacosColors.systemRedColor),
      ),
    ),
  );
}

/// What a diff surface shows when there is nothing to show.
class DiffEmpty extends StatelessWidget {
  const DiffEmpty({super.key, this.message = 'No changes'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(message, style: MacosTheme.of(context).typography.body),
  );
}

// ---------------------------------------------------------------------------
// The flat renderer
// ---------------------------------------------------------------------------

/// Renders a raw unified diff (from `git diff` / `git show`) with per-line
/// syntax colouring in a monospace font. Uses [ListView.builder] so large patches
/// stay responsive.
///
/// [wrap] chooses the line-length behavior:
///  * false (default): every line stays on one line and the whole diff shares
///    ONE horizontal pan (see [DiffPan]), so you can scroll all lines together
///    to reach their ends. Uniform row height keeps the fixed [kDiffLineExtent]
///    item extent (O(1) jump-scroll on large patches).
///  * true: long lines wrap to the viewport width (variable row heights, no
///    horizontal scroll).
///
/// This is also the fallback every richer renderer degrades to when it cannot
/// parse a patch into hunks — so it must always be able to show the diff.
class DiffView extends StatefulWidget {
  final String diff;
  final bool wrap;

  const DiffView({super.key, required this.diff, this.wrap = false});

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  // Separate controllers so the two nested scrollbars (vertical list, shared
  // horizontal pan) each drive an unambiguous axis.
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  /// Off the UI thread for a huge patch; inline otherwise. Same threshold as
  /// the hunk/split renderers — a 50k-line lockfile must not hitch a frame
  /// just because it fell through to the flat view (binary, `-w`, untracked).
  final DiffParser<List<String>> _parser = DiffParser(_splitDiffLines);

  List<String> _lines = const [];

  /// Syntax runs per source line, parallel to [_lines] (null for headers and
  /// when highlighting is skipped). Computed with the split so it's off the
  /// render path.
  List<List<ScopedRun>?> _lineRuns = const [];
  double _maxLineWidth = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _startLoad(widget.diff, initial: true);
  }

  @override
  void didUpdateWidget(DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Skip re-splitting when nothing actually changed — diff providers commonly
    // hand back the same content across otherwise-unrelated rebuilds (a theme
    // change, a parent resize).
    if (oldWidget.diff != widget.diff) {
      _startLoad(widget.diff, initial: false);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _startLoad(String diff, {required bool initial}) {
    void apply(List<String> lines, {required bool loading}) {
      _lines = lines;
      _lineRuns = highlightRawDiffLines(lines);
      _loading = loading;
      _maxLineWidth = measureDiffWidth(lines);
    }

    final inline = _parser.parse(
      diff,
      onDone: (lines) {
        if (!mounted) return;
        setState(() => apply(lines, loading: false));
      },
      onFailed: () {
        if (!mounted) return;
        // Degrade: split inline on the UI thread rather than spin forever.
        // A failed isolate is rare; the split itself is cheap enough for the
        // fallback path that the user still sees their diff.
        setState(
          () => apply(const LineSplitter().convert(diff), loading: false),
        );
      },
    );

    if (initial) {
      inline == null ? _loading = true : apply(inline.result, loading: false);
      return;
    }
    setState(() {
      inline == null ? _loading = true : apply(inline.result, loading: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.diff.trim().isEmpty) return const DiffEmpty();
    if (_loading) return const DiffPending();

    final macosTheme = MacosTheme.of(context);
    final defaultColor =
        macosTheme.typography.body.color ?? MacosColors.textColor;
    final codeTheme = codeThemeFor(macosTheme.brightness);

    if (widget.wrap) return _list(defaultColor, codeTheme, null);
    return DiffPan(
      vertical: _vertical,
      horizontal: _horizontal,
      maxLineWidth: _maxLineWidth,
      builder: (context, contentWidth, _) =>
          _list(defaultColor, codeTheme, contentWidth),
    );
  }

  // One SelectionArea over plain Text lines (not per-line SelectableText):
  // selection state doesn't span separate SelectableText widgets, so the old
  // shape made it impossible to drag-copy a multi-line hunk. This is the same
  // pattern the blame sheet uses, and each row is lighter too.
  Widget _list(Color defaultColor, CodeTheme codeTheme, double? contentWidth) {
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 8),
        // Wrapped lines have variable height, so no fixed extent then — the
        // builder still lazily measures only the visible rows.
        itemExtent: widget.wrap ? null : kDiffLineExtent,
        itemCount: _lines.length,
        itemBuilder: (context, index) {
          final line = _lines[index];
          return _diffTextRow(
            line,
            runs: index < _lineRuns.length ? _lineRuns[index] : null,
            codeTheme: codeTheme,
            defaultColor: defaultColor,
            contentWidth: contentWidth,
            wrap: widget.wrap,
          );
        },
      ),
    );
  }
}

/// Top-level so [DiffParser] can ship it to `Isolate.run`.
List<String> _splitDiffLines(String diff) => const LineSplitter().convert(diff);

/// One unified-diff text row: soft add/remove band spanning the full content
/// width, fixed strut so [kDiffLineExtent] never clips the glyphs, shared pad.
/// Content lines ([runs] non-null) are syntax-coloured while keeping the
/// add/remove sense; headers keep their single flat colour.
Widget _diffTextRow(
  String line, {
  required Color defaultColor,
  List<ScopedRun>? runs,
  CodeTheme? codeTheme,
  double? contentWidth,
  bool wrap = false,
}) {
  final Widget child = (runs != null && codeTheme != null)
      ? Text.rich(
          diffLineSpan(
            line,
            DiffLineHighlight(diffLineKind(line), runs),
            kDiffMono,
            defaultColor,
            codeTheme,
          ),
          maxLines: wrap ? null : 1,
          softWrap: wrap,
          strutStyle: wrap ? null : kDiffStrut,
        )
      : Text(
          line,
          maxLines: wrap ? null : 1,
          softWrap: wrap,
          strutStyle: wrap ? null : kDiffStrut,
          style: kDiffMono.copyWith(color: diffLineColor(line, defaultColor)),
        );
  return Container(
    width: contentWidth,
    color: diffLineBackground(line),
    padding: const EdgeInsets.symmetric(horizontal: kDiffHPad),
    alignment: Alignment.centerLeft,
    child: child,
  );
}
