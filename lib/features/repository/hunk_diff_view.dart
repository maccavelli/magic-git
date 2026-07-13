import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import '../common/diff_view.dart';
import '../common/list_keyboard_nav.dart';

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

  /// Index of this hunk within its file — the cursor value keyboard hunk
  /// navigation (⌥↑/↓) walks, and what a header carries so a click can focus it.
  final int index;
  const _HeaderItem(this.hunk, this.index);
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
  for (var h = 0; h < file.hunks.length; h++) {
    final hunk = file.hunks[h];
    items.add(_HeaderItem(hunk, h));
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

/// The parsed [DiffFile] (kept so hunk-action callbacks can reference it) plus
/// its flattened render items — both produced in one pass so the whole parse
/// can move to a background isolate for huge diffs (see [_parseAndBuild]).
class _ParsedDiff {
  final DiffFile? file;
  final List<Object> items;
  const _ParsedDiff(this.file, this.items);
}

/// Parses [diff] and flattens it in a single call — the unit of work handed to
/// `Isolate.run` above [_HunkDiffViewState._isolateLineThreshold].
_ParsedDiff _parseAndBuild(String diff) {
  final file = parseUnifiedDiff(diff);
  if (file == null) return const _ParsedDiff(null, []);
  return _ParsedDiff(file, _buildItems(file));
}

/// Test hook: exercises the exact parse+flatten payload that the render path
/// runs (inline for small diffs, on a background isolate for huge ones),
/// exposing plain counts so a test can assert correctness without a real
/// isolate — `Isolate.run` can't be driven inside flutter_test's custom zone.
@visibleForTesting
({int items, int hunks, bool parsed}) debugParseHunkDiff(String diff) {
  final parsed = _parseAndBuild(diff);
  return (
    items: parsed.items.length,
    hunks: parsed.file?.hunks.length ?? 0,
    parsed: parsed.file != null,
  );
}

class _HunkDiffViewState extends State<HunkDiffView> {
  // Below this line count, parse + flatten runs inline: an isolate spawn's own
  // overhead would dwarf the work for the vast majority of diffs, and this
  // keeps the common case free of spawn latency. Only a genuinely huge patch —
  // a regenerated lockfile / minified bundle diff, tens of thousands of lines —
  // crosses this and moves the parse off the UI thread so selecting it can't
  // jank a frame. Mirrors [SplitDiffView]'s identical guard.
  static const _isolateLineThreshold = 20000;

  DiffFile? _file;
  List<Object> _items = const [];
  bool _loading = false;

  /// Bumped on every load so a stale isolate result (superseded by a newer
  /// `diff`) can't clobber state after this widget has moved on.
  int _requestId = 0;

  // Keyboard hunk navigation: click a hunk header to focus it, then ⌥↑/↓ walk
  // the cursor and ⌘⇧K stages (or unstages) the focused hunk. Kept on the diff's
  // own focus node — not the keymap — so it engages only when the diff is
  // focused, and never fights text selection on the diff lines.
  final FocusNode _hunkFocus = FocusNode(debugLabel: 'hunk-nav');
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _headerKeys = {};
  int _focusedHunk = -1;

  @override
  void initState() {
    super.initState();
    _startLoad(widget.diff, initial: true);
  }

  @override
  void dispose() {
    _hunkFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _headerKeyFor(int index) =>
      _headerKeys.putIfAbsent(index, GlobalKey.new);

  void _focusHunk(int index) {
    _hunkFocus.requestFocus();
    setState(() => _focusedHunk = index);
    ensureRowVisible(_headerKeyFor(index), alignment: 0.15);
  }

  void _moveHunk(int dir) {
    final count = _file?.hunks.length ?? 0;
    if (count == 0) return;
    _focusHunk(stepSelection(_focusedHunk, dir, count));
  }

  void _actOnFocusedHunk() {
    final file = _file;
    if (file == null || _focusedHunk < 0 || _focusedHunk >= file.hunks.length) {
      return;
    }
    widget.onAction(
      file,
      file.hunks[_focusedHunk],
      widget.staged ? HunkAction.unstage : HunkAction.stage,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    // ⌥↑/↓ move the hunk cursor; ⌘⇧K stages/unstages the focused hunk.
    if (keys.isAltPressed && !keys.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _moveHunk(1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _moveHunk(-1);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.keyK &&
        keys.isMetaPressed &&
        keys.isShiftPressed) {
      _actOnFocusedHunk();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(HunkDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same object identity, not just equal content, is the common case: diff
    // providers hand back the same String instance across unrelated
    // rebuilds, so this skips reparsing when nothing actually changed.
    if (oldWidget.diff != widget.diff) {
      _startLoad(widget.diff, initial: false);
    }
  }

  int _lineCount(String s) => '\n'.allMatches(s).length + 1;

  void _startLoad(String diff, {required bool initial}) {
    final requestId = ++_requestId;
    if (_lineCount(diff) <= _isolateLineThreshold) {
      final parsed = _parseAndBuild(diff);
      // During initState (initial), the imminent first build reads the fields
      // directly — no setState needed (and it isn't allowed yet).
      if (initial) {
        _file = parsed.file;
        _items = parsed.items;
        _loading = false;
      } else {
        setState(() {
          _file = parsed.file;
          _items = parsed.items;
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
    Isolate.run(() => _parseAndBuild(diff)).then(
      (parsed) {
        if (!mounted || requestId != _requestId) return;
        setState(() {
          _file = parsed.file;
          _items = parsed.items;
          _loading = false;
        });
      },
      // Without this arm, a parse that failed on the isolate — or an isolate
      // that failed to spawn at all, which is a live possibility precisely
      // because this path is reserved for the biggest diffs — left [_loading]
      // true with nothing left to clear it. The pane spun forever and the error
      // went out as an unhandled async error, where no user could see it.
      //
      // Degrade instead of hanging: fall back to the plain read-only [DiffView],
      // which is the same thing `build` already shows for a diff it cannot parse
      // into hunks. Per-hunk staging is lost for this one diff; the diff itself
      // still renders, which is what the user came for.
      onError: (Object _, StackTrace _) {
        if (!mounted || requestId != _requestId) return;
        setState(() {
          _file = null;
          _items = const [];
          _loading = false;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: ProgressCircle());
    final file = _file;
    if (file == null) return DiffView(diff: widget.diff);

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;
    // SelectionArea + plain Text lines so a drag can copy across lines (and
    // across hunk boundaries) — per-line SelectableText couldn't span rows.
    return Focus(
      focusNode: _hunkFocus,
      onKeyEvent: _onKey,
      child: Scrollbar(
        controller: _scroll,
        child: SelectionArea(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final item = _items[i];
              if (item is _HeaderItem) {
                return _header(file, item.hunk, item.index);
              }
              return _line(item as _LineItem, defaultColor);
            },
          ),
        ),
      ),
    );
  }

  Widget _header(DiffFile file, DiffHunk hunk, int index) {
    final focused = _focusedHunk == index;
    return GestureDetector(
      key: _headerKeyFor(index),
      // Click a header to focus its hunk for keyboard nav; the Stage/Unstage/
      // Discard buttons inside keep their own taps.
      onTap: () => _focusHunk(index),
      child: Container(
      color: focused
          ? MacosColors.systemBlueColor.withValues(alpha: 0.22)
          : MacosColors.systemGrayColor.withValues(alpha: 0.10),
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
        child: Text(
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
