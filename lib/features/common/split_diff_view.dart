import 'dart:isolate';
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
/// stays in the unified [HunkDiffView]. Falls back to the plain [DiffView] when
/// the diff has no parseable hunks (binary / mode-only change).
class SplitDiffView extends StatefulWidget {
  final String diff;

  const SplitDiffView({super.key, required this.diff});

  @override
  State<SplitDiffView> createState() => _SplitDiffViewState();
}

class _SplitDiffViewState extends State<SplitDiffView> {
  // Below this line count, parsing + splitting runs inline — an isolate
  // spawn's own overhead would dwarf the work for the vast majority of diffs
  // (even a hefty few-thousand-line hunk parses in well under a frame), and
  // this keeps the common case free of spawn latency (mirrors
  // repoStructureProvider's cheap-signal-first, threshold-gated Isolate.run
  // in app_providers.dart). Only a genuinely huge patch — tens of thousands
  // of lines, big enough to risk visibly janking a frame — crosses this and
  // moves the work to a background isolate.
  static const _isolateLineThreshold = 20000;

  List<Object>? _items;
  bool _loading = false;

  /// Bumped on every load so a stale isolate result (superseded by a newer
  /// `diff`) can't clobber state after this widget has moved on.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    // Not routed through setState: this runs during initState, before this
    // element's first build, so mutating the fields directly is enough — the
    // imminent first build already picks up the new values.
    _startLoad(widget.diff, initial: true);
  }

  @override
  void didUpdateWidget(SplitDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same object identity, not just equal content, is the common case: diff
    // providers hand back the same String instance across unrelated
    // rebuilds, so this skips rebuilding the rows when nothing actually
    // changed.
    if (oldWidget.diff != widget.diff) {
      _startLoad(widget.diff, initial: false);
    }
  }

  int _lineCount(String s) => '\n'.allMatches(s).length + 1;

  void _startLoad(String diff, {required bool initial}) {
    final requestId = ++_requestId;
    if (_lineCount(diff) <= _isolateLineThreshold) {
      final items = _buildSplitItems(diff);
      if (initial) {
        _items = items;
        _loading = false;
      } else {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
      return;
    }

    if (initial) {
      _loading = true;
    } else {
      setState(() => _loading = true);
    }
    Isolate.run(() => _buildSplitItems(diff)).then((items) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: ProgressCircle());
    }
    final items = _items;
    if (items == null) return DiffView(diff: widget.diff);

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;
    return Scrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          if (item is _HeaderRow) {
            return Container(
              color: MacosColors.systemGrayColor.withValues(alpha: 0.10),
              padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
              child: Text(
                item.text,
                style: kDiffMono.copyWith(color: MacosColors.systemTealColor),
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
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _cell(row.left, isAdd: false, defaultColor: defaultColor, isContext: row.isContext)),
          Container(width: 1, color: MacosColors.separatorColor),
          Expanded(child: _cell(row.right, isAdd: true, defaultColor: defaultColor, isContext: row.isContext)),
        ],
      ),
    );
  }

  Widget _cell(
    String? text, {
    required bool isAdd,
    required Color defaultColor,
    required bool isContext,
  }) {
    final Color bg;
    final Color fg;
    if (text == null) {
      bg = MacosColors.systemGrayColor.withValues(alpha: 0.06);
      fg = defaultColor;
    } else if (isContext) {
      bg = const Color(0x00000000);
      fg = defaultColor;
    } else if (isAdd) {
      bg = MacosColors.systemGreenColor.withValues(alpha: 0.12);
      fg = MacosColors.systemGreenColor;
    } else {
      bg = MacosColors.systemRedColor.withValues(alpha: 0.12);
      fg = MacosColors.systemRedColor;
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text ?? '',
          style: kDiffMono.copyWith(color: fg),
        ),
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
      rows.add(_SplitRow(
        left: k < removes.length ? removes[k] : null,
        right: k < adds.length ? adds[k] : null,
      ));
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
