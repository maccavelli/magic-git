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

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

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
          return _rowWidget(item as _SplitRow, defaultColor);
        },
      ),
    );
  }

  Widget _rowWidget(_SplitRow row, Color defaultColor) {
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
              isContext: row.isContext,
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
      bg = diffKindBackground(kind) ?? const Color(0x00000000);
      fg = diffKindColor(kind, defaultColor);
    }
    return Container(
      color: bg,
      // Same horizontal inset as every other diff surface.
      padding: const EdgeInsets.symmetric(horizontal: kDiffHPad, vertical: 1),
      // A one-line minimum so a gutter (null side) is never shorter than its
      // counterpart's first line, and empty lines keep the mono rhythm.
      constraints: const BoxConstraints(minHeight: kDiffLineExtent),
      alignment: Alignment.centerLeft,
      child: Text(
        text ?? '',
        // Wrap within the cell: the column is exactly half the pane, so a
        // long line folds instead of pushing its neighbour off the screen.
        softWrap: true,
        strutStyle: kDiffStrut,
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
