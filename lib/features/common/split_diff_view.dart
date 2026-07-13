import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import 'diff_view.dart';

/// One side-by-side row: the old-side line (left) and/or the new-side line
/// (right). A pure context line fills both; a removal fills only [left]; an
/// addition only [right].
class _SplitRow {
  final String? left;
  final String? right;
  final bool isContext;
  const _SplitRow({this.left, this.right, this.isContext = false});
}

/// A hunk header row (rendered full-width across both columns).
class _HeaderRow {
  final String text;
  const _HeaderRow(this.text);
}

/// Parses [diff] and flattens it into the header/row items [SplitDiffView]
/// renders. Returns null when there's nothing hunk-parseable (binary /
/// mode-only change).
///
/// Top-level, because [DiffParser] hands it to `Isolate.run` for a big patch.
List<Object>? _buildSplitItems(String diff) {
  final file = parseUnifiedDiff(diff);
  if (file == null) return null;
  final items = <Object>[];
  for (final hunk in file.hunks) {
    items.add(_HeaderRow(hunk.header));
    items.addAll(_splitHunk(hunk));
  }
  return items;
}

/// Renders a unified diff as a **side-by-side** (split) view: removals on the
/// left, additions on the right, context on both. Read-only — hunk staging
/// stays in the unified `HunkDiffView`. Falls back to the plain [DiffView] when
/// the diff has no parseable hunks (binary / mode-only change), or when parsing
/// it fails outright.
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
  final ScrollController _horizontal = ScrollController();

  List<Object>? _items;
  bool _loading = false;

  /// Widest cell text, sizing the shared horizontal pan. Recomputed only when
  /// the rows change — not on every layout pass.
  double _maxLineWidth = 0;

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
    _horizontal.dispose();
    super.dispose();
  }

  void _startLoad(String diff, {required bool initial}) {
    // During initState the imminent first build reads the fields directly — no
    // setState needed, and it isn't allowed yet.
    void apply(List<Object>? items, {required bool loading}) {
      _items = items;
      _loading = loading;
      _maxLineWidth = items == null ? 0 : measureDiffWidth(_cellTexts(items));
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

  /// Every rendered cell's text, for the width measurement.
  static Iterable<String> _cellTexts(List<Object> items) sync* {
    for (final item in items) {
      if (item is _HeaderRow) {
        yield item.text;
      } else if (item is _SplitRow) {
        // Each column is half the pan, but a cell is measured whole: it is the
        // longest single cell that decides how far there is to scroll.
        if (item.left != null) yield item.left!;
        if (item.right != null) yield item.right!;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const DiffPending();
    final items = _items;
    if (items == null) return DiffView(diff: widget.diff);

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

    return DiffPan(
      vertical: _vertical,
      horizontal: _horizontal,
      // Two columns side by side, so the pan has to be wide enough for the
      // widest cell to clear *its half* of it.
      maxLineWidth: _maxLineWidth * 2,
      builder: (context, _, viewportWidth) =>
          _list(items, defaultColor, viewportWidth),
    );
  }

  // SelectionArea + plain Text cells so a drag can copy across rows — per-cell
  // SelectableText couldn't span them.
  Widget _list(List<Object> items, Color defaultColor, double viewportWidth) {
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          if (item is _HeaderRow) {
            // A header spans both columns and names the hunk — pin it, so it
            // stays readable however far the diff is panned.
            return DiffPinnedRow(
              horizontal: _horizontal,
              viewportWidth: viewportWidth,
              child: Container(
                color: MacosColors.systemGrayColor.withValues(alpha: 0.10),
                padding: const EdgeInsets.fromLTRB(kDiffHPad, 4, 6, 4),
                child: Text(
                  item.text,
                  style: kDiffMono.copyWith(color: kDiffHunkHeaderColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          }
          return _rowWidget(item as _SplitRow, defaultColor);
        },
      ),
    );
  }

  Widget _rowWidget(_SplitRow row, Color defaultColor) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _cell(
              row.left,
              kind: DiffLineKind.remove,
              defaultColor: defaultColor,
              isContext: row.isContext,
            ),
          ),
          Container(width: 1, color: MacosColors.separatorColor),
          Expanded(
            child: _cell(
              row.right,
              kind: DiffLineKind.add,
              defaultColor: defaultColor,
              isContext: row.isContext,
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
    required bool isContext,
  }) {
    final Color bg;
    final Color fg;
    if (text == null) {
      // No counterpart on this side — a gutter, not a line.
      bg = MacosColors.systemGrayColor.withValues(alpha: 0.06);
      fg = defaultColor;
    } else if (isContext) {
      bg = const Color(0x00000000);
      fg = diffKindColor(DiffLineKind.context, defaultColor);
    } else {
      bg = diffKindColor(kind, defaultColor).withValues(alpha: 0.12);
      fg = diffKindColor(kind, defaultColor);
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Text(
        text ?? '',
        maxLines: 1,
        softWrap: false,
        style: kDiffMono.copyWith(color: fg),
      ),
    );
  }
}

/// Aligns a hunk's raw lines into split rows. Consecutive removals and
/// additions are zipped (removal i ↔ addition i); leftovers become one-sided
/// rows. Context lines flush any pending run, then fill both columns.
List<_SplitRow> _splitHunk(DiffHunk hunk) {
  final rows = <_SplitRow>[];
  final removes = <String>[];
  final adds = <String>[];

  void flush() {
    final n = removes.length > adds.length ? removes.length : adds.length;
    for (var k = 0; k < n; k++) {
      rows.add(
        _SplitRow(
          left: k < removes.length ? removes[k] : null,
          right: k < adds.length ? adds[k] : null,
        ),
      );
    }
    removes.clear();
    adds.clear();
  }

  for (final l in hunk.lines) {
    switch (diffLineKind(l)) {
      case DiffLineKind.add:
        adds.add(l.length > 1 ? l.substring(1) : '');
      case DiffLineKind.remove:
        removes.add(l.length > 1 ? l.substring(1) : '');
      case DiffLineKind.context:
        flush();
        final text = l.isNotEmpty ? l.substring(1) : '';
        rows.add(_SplitRow(left: text, right: text, isContext: true));
      case DiffLineKind.noNewline:
      case DiffLineKind.other:
        // "\ No newline…" and stray markers don't map to a side — skip.
        break;
    }
  }
  flush();
  return rows;
}
