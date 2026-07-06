import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import '../common/diff_view.dart';

/// What a per-hunk button does, given whether the index or worktree diff is
/// shown.
enum HunkAction { stage, unstage, discard }

/// A tracked file's diff, grouped by hunk, each hunk carrying stage/unstage/
/// discard actions. Falls back to a plain [DiffView] when the diff has no hunks
/// (binary or mode-only change), so those still render.
class HunkDiffView extends StatefulWidget {
  final String diff;

  /// True when showing the index (`--cached`) diff — its hunks can be unstaged;
  /// false for the worktree diff — its hunks can be staged or discarded.
  final bool staged;
  final void Function(DiffFile file, DiffHunk hunk, HunkAction action) onAction;

  const HunkDiffView({
    super.key,
    required this.diff,
    required this.staged,
    required this.onAction,
  });

  @override
  State<HunkDiffView> createState() => _HunkDiffViewState();
}

/// A hunk-header row (rendered full-width, carries the hunk's stage/unstage/
/// discard actions).
class _HeaderItem {
  final DiffHunk hunk;
  const _HeaderItem(this.hunk);
}

/// A single hunk body line. [isFirst]/[isLast] mark its position within the
/// hunk's line run so the surrounding padding (originally one [Padding]
/// wrapping the whole run) can be reproduced exactly across separately-built
/// items: only the first line carries the top inset and only the last carries
/// the bottom inset.
class _LineItem {
  final String text;
  final bool isFirst;
  final bool isLast;
  const _LineItem(this.text, {required this.isFirst, required this.isLast});
}

/// Flattens [file]'s hunks into the header/line items [HunkDiffView] renders
/// in a single lazily-built list — the same header-then-lines shape as the
/// eager version, just flattened so [ListView.builder] can build only the
/// on-screen items instead of every line of every hunk up front.
List<Object> _buildItems(DiffFile file) {
  final items = <Object>[];
  for (final hunk in file.hunks) {
    items.add(_HeaderItem(hunk));
    for (var i = 0; i < hunk.lines.length; i++) {
      items.add(
        _LineItem(
          hunk.lines[i],
          isFirst: i == 0,
          isLast: i == hunk.lines.length - 1,
        ),
      );
    }
  }
  return items;
}

class _HunkDiffViewState extends State<HunkDiffView> {
  DiffFile? _file;
  List<Object> _items = const [];

  @override
  void initState() {
    super.initState();
    _file = parseUnifiedDiff(widget.diff);
    final file = _file;
    if (file != null) _items = _buildItems(file);
  }

  @override
  void didUpdateWidget(HunkDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same object identity, not just equal content, is the common case: diff
    // providers hand back the same String instance across unrelated
    // rebuilds, so this skips reparsing when nothing actually changed.
    if (oldWidget.diff != widget.diff) {
      _file = parseUnifiedDiff(widget.diff);
      final file = _file;
      _items = file == null ? const [] : _buildItems(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) return DiffView(diff: widget.diff);

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;
    return Scrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final item = _items[i];
          if (item is _HeaderItem) {
            return _header(file, item.hunk);
          }
          return _line(item as _LineItem, defaultColor);
        },
      ),
    );
  }

  Widget _header(DiffFile file, DiffHunk hunk) {
    return Container(
      color: MacosColors.systemGrayColor.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hunk.header,
              style: kDiffMono.copyWith(color: MacosColors.systemTealColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.staged)
            _btn(
              'Unstage',
              () => widget.onAction(file, hunk, HunkAction.unstage),
            )
          else ...[
            _btn(
              'Stage',
              () => widget.onAction(file, hunk, HunkAction.stage),
            ),
            const SizedBox(width: 6),
            _btn(
              'Discard',
              () => widget.onAction(file, hunk, HunkAction.discard),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(_LineItem line, Color defaultColor) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        line.isFirst ? 4 : 0,
        12,
        line.isLast ? 8 : 0,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          line.text,
          style: kDiffMono.copyWith(
            color: diffLineColor(line.text, defaultColor),
          ),
        ),
      ),
    );
  }

  Widget _btn(String label, VoidCallback onPressed) => PushButton(
    controlSize: ControlSize.small,
    secondary: true,
    onPressed: onPressed,
    child: Text(label),
  );
}
