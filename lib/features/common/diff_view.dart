import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';

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

/// The exact rendered height of one diff line — [kDiffMono]'s fontSize × its
/// line-height. Every line in the flat [DiffView] is a single, non-wrapping
/// monospace line, so pinning this as a uniform `itemExtent` lets the list skip
/// per-line layout for its scroll math (O(1) jump-scroll on large patches)
/// without changing the layout, since it equals each line's intrinsic height.
const double kDiffLineExtent = 12 * 1.35; // = 16.2

/// Horizontal inset on every diff line, in every renderer.
const double kDiffHPad = 12;

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
    return AnimatedBuilder(
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
    );
  }
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

/// How an action reads: an ordinary one, or one that throws work away.
enum DiffActionTone { normal, destructive }

/// The button a diff row offers for an action on the thing it labels — Stage,
/// Unstage, Discard on a hunk header.
///
/// These sit *inside* the diff, on a coloured band, at 18px tall, and the stock
/// [PushButton] was the wrong instrument for that: a chrome-grey slab with a hard
/// border that reads as a Windows dialog button dropped into a code listing. It
/// also gave no hover feedback at all and left the pointer a plain arrow, so the
/// only way to discover the thing was live was to click it and see.
///
/// So: a capsule that is nearly invisible at rest and lights up in the action's
/// own colour under the pointer — the accent for Stage/Unstage (the *system*
/// accent, so it matches whatever the user picked in System Settings), red for
/// Discard, which is the one that destroys work. The pointer becomes a hand, the
/// surface brightens, the border finds its colour and the whole thing lifts a
/// hair; pressing it presses *in*. Every one of those is a separate, redundant
/// signal that this is a live control, because the complaint that produced this
/// widget was that it looked dead.
class DiffActionButton extends StatefulWidget {
  const DiffActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tone = DiffActionTone.normal,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final DiffActionTone tone;

  @override
  State<DiffActionButton> createState() => _DiffActionButtonState();
}

class _DiffActionButtonState extends State<DiffActionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness.isDark;
    final accent = switch (widget.tone) {
      DiffActionTone.normal => theme.primaryColor,
      DiffActionTone.destructive => MacosColors.systemRedColor,
    };

    // At rest the capsule is just a faint pane of glass over the header band —
    // present, legible, but not competing with the code. Under the pointer it
    // becomes the accent; held down, more of it.
    final (Color fill, Color border, Color fg) = switch ((_pressed, _hovered)) {
      (true, _) => (
        accent.withValues(alpha: dark ? 0.55 : 0.85),
        accent,
        dark ? MacosColors.white : MacosColors.white,
      ),
      (_, true) => (
        accent.withValues(alpha: dark ? 0.32 : 0.16),
        accent.withValues(alpha: dark ? 0.75 : 0.55),
        dark ? MacosColors.white : accent,
      ),
      _ => (
        dark
            ? MacosColors.white.withValues(alpha: 0.10)
            : MacosColors.white.withValues(alpha: 0.75),
        dark
            ? MacosColors.white.withValues(alpha: 0.16)
            : MacosColors.black.withValues(alpha: 0.14),
        theme.typography.body.color ?? MacosColors.textColor,
      ),
    };

    return MouseRegion(
      // The signal the old button never gave. Note this MouseRegion has to sit
      // *outside* everything: a Text under a SelectionArea wraps itself in an
      // I-beam MouseRegion, and the deepest annotation under the pointer is the
      // one that wins — which is exactly how the pointer stayed an I-beam over a
      // perfectly live button. Callers keep these out of the selection scope
      // (see SelectionContainer.disabled); this is the belt to that's braces.
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          height: 18,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            // A vertical sheen rather than a flat fill — the thing that makes a
            // small macOS control look like a physical surface catching light
            // from above instead of a rectangle of colour.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                  MacosColors.white.withValues(alpha: dark ? 0.08 : 0.35),
                  fill,
                ),
                fill,
              ],
            ),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: border, width: 0.5),
            boxShadow: [
              // Lifted while hovered, sunk while pressed, resting otherwise.
              if (!_pressed)
                BoxShadow(
                  color: MacosColors.black.withValues(
                    alpha: _hovered ? 0.22 : 0.10,
                  ),
                  blurRadius: _hovered ? 3 : 1,
                  offset: Offset(0, _hovered ? 1 : 0.5),
                ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MacosIcon(widget.icon, size: 9, color: fg),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: theme.typography.body.copyWith(
                  fontSize: 11,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
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
  Widget build(BuildContext context) =>
      const Center(child: ProgressCircle());
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
        '$error',
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

  late List<String> _lines = const LineSplitter().convert(widget.diff);
  late double _maxLineWidth = measureDiffWidth(_lines);

  @override
  void didUpdateWidget(DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Skip re-splitting when nothing actually changed — diff providers commonly
    // hand back the same content across otherwise-unrelated rebuilds (a theme
    // change, a parent resize).
    if (oldWidget.diff != widget.diff) {
      _lines = const LineSplitter().convert(widget.diff);
      _maxLineWidth = measureDiffWidth(_lines);
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
    if (widget.diff.trim().isEmpty) return const DiffEmpty();

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

    if (widget.wrap) return _list(defaultColor);
    return DiffPan(
      vertical: _vertical,
      horizontal: _horizontal,
      maxLineWidth: _maxLineWidth,
      builder: (context, _, _) => _list(defaultColor),
    );
  }

  // One SelectionArea over plain Text lines (not per-line SelectableText):
  // selection state doesn't span separate SelectableText widgets, so the old
  // shape made it impossible to drag-copy a multi-line hunk. This is the same
  // pattern the blame sheet uses, and each row is lighter too.
  Widget _list(Color defaultColor) {
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 12),
        // Wrapped lines have variable height, so no fixed extent then — the
        // builder still lazily measures only the visible rows.
        itemExtent: widget.wrap ? null : kDiffLineExtent,
        itemCount: _lines.length,
        itemBuilder: (context, index) {
          final line = _lines[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: kDiffHPad),
            child: Text(
              line,
              maxLines: widget.wrap ? null : 1,
              softWrap: widget.wrap,
              style: kDiffMono.copyWith(
                color: diffLineColor(line, defaultColor),
              ),
            ),
          );
        },
      ),
    );
  }
}
