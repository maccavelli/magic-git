import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import '../viewer/code_view.dart' show CodeTheme, codeThemeFor;
import 'diff_highlight.dart';
import 'diff_view.dart';

/// One side-by-side row: the old-side line (left) and/or the new-side line
/// (right). A pure context line fills both; a removal fills only [left]; an
/// addition only [right]. Each side carries its precomputed syntax runs
/// ([leftRuns]/[rightRuns] are null when highlighting was skipped — the cell
/// still renders, coloured by kind).
class _SplitRow {
  final String? left;
  final String? right;
  final bool isContext;
  final List<ScopedRun>? leftRuns;
  final List<ScopedRun>? rightRuns;
  const _SplitRow({
    this.left,
    this.right,
    this.isContext = false,
    this.leftRuns,
    this.rightRuns,
  });
}

/// A hunk header row (rendered full-width across both columns).
class _HeaderRow {
  final String text;
  const _HeaderRow(this.text);
}

/// Parses [diff] and flattens it into the header/row items [SplitDiffView]
/// renders, with per-side syntax highlighting attached. Returns null when
/// there's nothing hunk-parseable (binary / mode-only change).
///
/// The old (left) column is highlighted from the reconstructed pre-image and the
/// new (right) column from the post-image, each in one pass so grammar state is
/// correct. Highlighting rides this same function so it's off the UI thread for
/// a huge patch too, but is gated off above the isolate threshold (re-registering
/// grammars per ephemeral isolate isn't worth it) — those render kind-coloured.
///
/// Top-level, because [DiffParser] hands it to `Isolate.run` for a big patch.
List<Object>? _buildSplitItems(String diff) {
  final file = parseUnifiedDiff(diff);
  if (file == null) return null;
  final enable = diffLineCount(diff) <= kDiffIsolateLineThreshold;
  final lang = diffLanguageId(file);

  // Reconstruct both images across the whole file: the left column is the
  // pre-image (context + removals), the right the post-image (context +
  // additions), in hunk-body order.
  final preContent = <String>[];
  final postContent = <String>[];
  for (final hunk in file.hunks) {
    for (final l in hunk.lines) {
      switch (diffLineKind(l)) {
        case DiffLineKind.context:
          final t = l.isNotEmpty ? l.substring(1) : '';
          preContent.add(t);
          postContent.add(t);
        case DiffLineKind.remove:
          preContent.add(l.length > 1 ? l.substring(1) : '');
        case DiffLineKind.add:
          postContent.add(l.length > 1 ? l.substring(1) : '');
        case DiffLineKind.noNewline:
        case DiffLineKind.other:
          break;
      }
    }
  }
  final preRuns = highlightImageRuns(preContent, lang, enable: enable);
  final postRuns = highlightImageRuns(postContent, lang, enable: enable);

  final items = <Object>[];
  // File-global image cursors, advanced in lockstep with the reconstruction
  // above so each cell indexes the right highlighted line.
  var preIdx = 0;
  var postIdx = 0;
  for (final hunk in file.hunks) {
    items.add(_HeaderRow(hunk.header));
    (preIdx, postIdx) = _splitHunk(hunk, items, preRuns, postRuns, preIdx, postIdx);
  }
  return items;
}

/// Renders a unified diff as a **side-by-side** (split) view: removals on the
/// left, additions on the right, context on both. Read-only — hunk staging
/// stays in the unified `HunkDiffView`. Falls back to the plain [DiffView] when
/// the diff has no parseable hunks (binary / mode-only change), or when parsing
/// it fails outright.
///
/// The two columns always split the viewport equally, so BOTH sides are on
/// screen at every pane width; a cell whose text is wider than its column
/// wraps within the cell rather than panning the surface. The old shape sized
/// both columns from the single widest cell and panned the whole surface —
/// one long line anywhere pushed the additions column entirely off the pane,
/// which read as "the diff is missing its right half". Wrapping keeps the
/// left/right pair on one row (the row takes the taller cell's height), so
/// corresponding lines stay aligned however narrow the pane gets, and a
/// resize (pane divider, pop-out window) simply reflows.
class SplitDiffView extends StatefulWidget {
  final String diff;

  const SplitDiffView({super.key, required this.diff});

  @override
  State<SplitDiffView> createState() => _SplitDiffViewState();
}

class _SplitDiffViewState extends State<SplitDiffView> {
  /// Off the UI thread for a huge patch; inline for everything else. See
  /// [DiffParser].
  final DiffParser<List<Object>?> _parser = DiffParser(_buildSplitItems);

  final ScrollController _vertical = ScrollController();

  List<Object>? _items;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _startLoad(widget.diff, initial: true);
  }

  @override
  void didUpdateWidget(SplitDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Diff providers commonly hand back the same String instance across
    // otherwise-unrelated rebuilds, so this skips re-parsing when nothing
    // actually changed.
    if (oldWidget.diff != widget.diff) {
      _startLoad(widget.diff, initial: false);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    super.dispose();
  }

  void _startLoad(String diff, {required bool initial}) {
    // During initState the imminent first build reads the fields directly — no
    // setState needed, and it isn't allowed yet.
    void apply(List<Object>? items, {required bool loading}) {
      _items = items;
      _loading = loading;
    }

    final inline = _parser.parse(
      diff,
      onDone: (items) {
        if (!mounted) return;
        setState(() => apply(items, loading: false));
      },
      // Parse failed (or the isolate never spawned). Degrade to the read-only
      // DiffView — the same fallback used for a diff with no parseable hunks —
      // rather than leaving _loading true and the pane spinning forever.
      onFailed: () {
        if (!mounted) return;
        setState(() => apply(null, loading: false));
      },
    );

    // Null here means it went off-thread and hasn't landed: show the spinner.
    // (An inline parse that *returned* null — a binary diff, which has no rows —
    // is a result, not an absence; the record keeps the two apart.)
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
    if (_loading) return const DiffPending();
    final items = _items;
    if (items == null) return DiffView(diff: widget.diff);

    final macosTheme = MacosTheme.of(context);
    final defaultColor =
        macosTheme.typography.body.color ?? MacosColors.textColor;
    final codeTheme = codeThemeFor(macosTheme.brightness);

    // SelectionArea + plain Text cells so a drag can copy across rows —
    // per-cell SelectableText couldn't span them.
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 8),
        // Rows are as tall as their (possibly wrapped) taller cell, and
        // headers differ again — no fixed extent; the builder lazily lays
        // out only the visible rows.
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          if (item is _HeaderRow) {
            return Container(
              color: MacosColors.systemGrayColor.withValues(alpha: 0.10),
              padding: const EdgeInsets.fromLTRB(kDiffHPad, 4, 6, 4),
              child: Text(
                item.text,
                style: kDiffMono.copyWith(color: kDiffHunkHeaderColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          }
          return _rowWidget(item as _SplitRow, defaultColor, codeTheme);
        },
      ),
    );
  }

  Widget _rowWidget(_SplitRow row, Color defaultColor, CodeTheme codeTheme) {
    // IntrinsicHeight so the pair shares one height (the taller, wrapped
    // cell's) and the shorter side's background band fills the whole row —
    // corresponding lines stay visually aligned when one side wraps.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _cell(
              row.left,
              kind: DiffLineKind.remove,
              defaultColor: defaultColor,
              codeTheme: codeTheme,
              isContext: row.isContext,
              runs: row.leftRuns,
            ),
          ),
          Container(
            width: kDiffSplitSeparator,
            color: MacosColors.separatorColor,
          ),
          Expanded(
            child: _cell(
              row.right,
              kind: DiffLineKind.add,
              defaultColor: defaultColor,
              codeTheme: codeTheme,
              isContext: row.isContext,
              runs: row.rightRuns,
            ),
          ),
        ],
      ),
    );
  }

  /// One side of a row. The marker is long gone by here — which column a line
  /// landed in *is* its kind — so the colour comes from [diffKindColor] with
  /// that kind, which is the same call the unified views make. Green means the
  /// same thing in both, by construction rather than by coincidence.
  Widget _cell(
    String? text, {
    required DiffLineKind kind,
    required Color defaultColor,
    required CodeTheme codeTheme,
    required bool isContext,
    required List<ScopedRun>? runs,
  }) {
    // The cell's *kind* for colouring: a gutter/context cell is neutral; a
    // filled add/remove cell keeps its column's kind (which is what carries the
    // green/red).
    final cellKind = (text == null || isContext) ? DiffLineKind.context : kind;
    final Color bg;
    if (text == null) {
      bg = MacosColors.systemGrayColor.withValues(alpha: 0.06);
    } else if (isContext) {
      bg = const Color(0x00000000);
    } else {
      bg = diffKindBackground(kind) ?? const Color(0x00000000);
    }
    return Container(
      color: bg,
      // Same horizontal inset as every other diff surface.
      padding: const EdgeInsets.symmetric(horizontal: kDiffHPad, vertical: 1),
      // A one-line minimum so a gutter (null side) is never shorter than its
      // counterpart's first line, and empty lines keep the mono rhythm.
      constraints: const BoxConstraints(minHeight: kDiffLineExtent),
      alignment: Alignment.centerLeft,
      child: Text.rich(
        diffCellSpan(
          text ?? '',
          runs,
          cellKind,
          kDiffMono,
          defaultColor,
          codeTheme,
        ),
        // Wrap within the cell: the column is exactly half the pane, so a
        // long line folds instead of pushing its neighbour off the screen.
        softWrap: true,
        strutStyle: kDiffStrut,
      ),
    );
  }
}

/// Aligns a hunk's raw lines into split rows, appending them to [items].
/// Consecutive removals and additions are zipped (removal i ↔ addition i);
/// leftovers become one-sided rows. Context lines flush any pending run,
/// then fill both columns. Each cell picks up its syntax runs from [preRuns]
/// (left) / [postRuns] (right) at the running image index; returns the advanced
/// (preIdx, postIdx) for the next hunk.
(int, int) _splitHunk(
  DiffHunk hunk,
  List<Object> items,
  List<List<ScopedRun>?> preRuns,
  List<List<ScopedRun>?> postRuns,
  int preIdx,
  int postIdx,
) {
  // Buffered removal/addition runs as (content, imageIndex) pairs.
  final removes = <(String, int)>[];
  final adds = <(String, int)>[];

  void flush() {
    final n = removes.length > adds.length ? removes.length : adds.length;
    for (var k = 0; k < n; k++) {
      final r = k < removes.length ? removes[k] : null;
      final a = k < adds.length ? adds[k] : null;
      items.add(
        _SplitRow(
          left: r?.$1,
          right: a?.$1,
          leftRuns: r == null ? null : preRuns[r.$2],
          rightRuns: a == null ? null : postRuns[a.$2],
        ),
      );
    }
    removes.clear();
    adds.clear();
  }

  for (final l in hunk.lines) {
    switch (diffLineKind(l)) {
      case DiffLineKind.add:
        adds.add((l.length > 1 ? l.substring(1) : '', postIdx));
        postIdx++;
      case DiffLineKind.remove:
        removes.add((l.length > 1 ? l.substring(1) : '', preIdx));
        preIdx++;
      case DiffLineKind.context:
        flush();
        final text = l.isNotEmpty ? l.substring(1) : '';
        items.add(
          _SplitRow(
            left: text,
            right: text,
            isContext: true,
            leftRuns: preRuns[preIdx],
            rightRuns: postRuns[postIdx],
          ),
        );
        preIdx++;
        postIdx++;
      case DiffLineKind.noNewline:
      case DiffLineKind.other:
        // "\ No newline…" and stray markers don't map to a side — skip.
        break;
    }
  }
  flush();
  return (preIdx, postIdx);
}
