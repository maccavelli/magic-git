import 'package:flutter/cupertino.dart' show CupertinoIcons;
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
/// (binary or mode-only change), or when parsing it fails outright — so those
/// still render.
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

/// A single hunk body line.
class _LineItem {
  final String text;
  const _LineItem(this.text);
}

/// Flattens [file]'s hunks into the header/line items [HunkDiffView] renders in
/// a single lazily-built list, so [ListView.builder] can build only the
/// on-screen items instead of every line of every hunk up front.
List<Object> _buildItems(DiffFile file) {
  final items = <Object>[];
  for (var h = 0; h < file.hunks.length; h++) {
    final hunk = file.hunks[h];
    items.add(_HeaderItem(hunk, h));
    for (final line in hunk.lines) {
      items.add(_LineItem(line));
    }
  }
  return items;
}

/// The parsed [DiffFile] (kept so hunk-action callbacks can reference it) plus
/// its flattened render items — both produced in one pass so the whole parse can
/// move to a background isolate for huge diffs (see [DiffParser]).
class _ParsedDiff {
  final DiffFile? file;
  final List<Object> items;
  const _ParsedDiff(this.file, this.items);
}

/// Top-level, because [DiffParser] hands it to `Isolate.run` for a big patch.
_ParsedDiff _parseAndBuild(String diff) {
  final file = parseUnifiedDiff(diff);
  if (file == null) return const _ParsedDiff(null, []);
  return _ParsedDiff(file, _buildItems(file));
}

/// Test hook: exercises the exact parse+flatten payload the render path runs
/// (inline for small diffs, on a background isolate for huge ones), exposing
/// plain counts so a test can assert correctness without a real isolate —
/// `Isolate.run` can't be driven inside flutter_test's custom zone.
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
  final DiffParser<_ParsedDiff> _parser = DiffParser(_parseAndBuild);

  DiffFile? _file;
  List<Object> _items = const [];
  bool _loading = false;

  /// Widest body line, sizing the shared horizontal pan. Recomputed only when
  /// the rows change — not on every layout pass.
  double _maxLineWidth = 0;

  // Keyboard hunk navigation: click a hunk header to focus it, then ⌥↑/↓ walk
  // the cursor and ⌘⇧K stages (or unstages) the focused hunk. Kept on the diff's
  // own focus node — not the keymap — so it engages only when the diff is
  // focused, and never fights text selection on the diff lines.
  final FocusNode _hunkFocus = FocusNode(debugLabel: 'hunk-nav');
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
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
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HunkDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Diff providers commonly hand back the same String instance across
    // otherwise-unrelated rebuilds, so this skips re-parsing when nothing
    // actually changed.
    if (oldWidget.diff != widget.diff) {
      _startLoad(widget.diff, initial: false);
    }
  }

  void _startLoad(String diff, {required bool initial}) {
    void apply(_ParsedDiff? parsed, {required bool loading}) {
      _file = parsed?.file;
      _items = parsed?.items ?? const [];
      _loading = loading;
      _maxLineWidth = measureDiffWidth(_lineTexts(_items));
      // A hunk cursor from the previous diff means nothing against this one.
      _focusedHunk = -1;
    }

    final inline = _parser.parse(
      diff,
      onDone: (parsed) {
        if (!mounted) return;
        setState(() => apply(parsed, loading: false));
      },
      // Parse failed (or the isolate never spawned — likeliest on exactly the
      // giant patches that take that path). Degrade to the read-only DiffView,
      // the same fallback used for a diff with no parseable hunks, rather than
      // leaving _loading true and the pane spinning forever with nothing left
      // alive to clear it. Per-hunk staging is lost for this one diff; the diff
      // itself still renders, which is what the user came for.
      onFailed: () {
        if (!mounted) return;
        setState(() => apply(null, loading: false));
      },
    );

    // Null means it went off-thread and hasn't landed: show the spinner. During
    // initState the imminent first build reads the fields directly — no setState
    // needed, and it isn't allowed yet.
    if (initial) {
      inline == null ? _loading = true : apply(inline.result, loading: false);
      return;
    }
    setState(() {
      inline == null ? _loading = true : apply(inline.result, loading: false);
    });
  }

  static Iterable<String> _lineTexts(List<Object> items) sync* {
    for (final item in items) {
      if (item is _LineItem) yield item.text;
    }
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
  Widget build(BuildContext context) {
    if (_loading) return const DiffPending();
    final file = _file;
    if (file == null) return DiffView(diff: widget.diff);

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

    return Focus(
      focusNode: _hunkFocus,
      onKeyEvent: _onKey,
      child: DiffPan(
        vertical: _vertical,
        horizontal: _horizontal,
        maxLineWidth: _maxLineWidth,
        builder: (context, contentWidth, viewportWidth) =>
            _list(file, defaultColor, contentWidth, viewportWidth),
      ),
    );
  }

  // SelectionArea + plain Text lines so a drag can copy across lines (and across
  // hunk boundaries) — per-line SelectableText couldn't span rows.
  Widget _list(
    DiffFile file,
    Color defaultColor,
    double contentWidth,
    double viewportWidth,
  ) {
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final item = _items[i];
          if (item is _HeaderItem) {
            return _header(file, item.hunk, item.index, viewportWidth);
          }
          return _line(item as _LineItem, defaultColor, contentWidth);
        },
      ),
    );
  }

  /// A hunk's header, carrying its actions — and pinned to the viewport, so
  /// panning right to read the end of a long line cannot carry Stage / Unstage /
  /// Discard off the screen with it. Its buttons must be reachable at any pan.
  Widget _header(
    DiffFile file,
    DiffHunk hunk,
    int index,
    double viewportWidth,
  ) {
    final focused = _focusedHunk == index;
    return DiffPinnedRow(
      horizontal: _horizontal,
      viewportWidth: viewportWidth,
      // The label and buttons are chrome, not diff text: keeping them out of
      // the SelectionArea means a drag-copy of the diff doesn't pick up
      // "Stage"/"Discard" along with the code.
      child: SelectionContainer.disabled(
        child: GestureDetector(
          key: _headerKeyFor(index),
          // Click a header to focus its hunk for keyboard nav; the Stage/
          // Unstage/Discard buttons inside keep their own taps.
          onTap: () => _focusHunk(index),
          child: Container(
            decoration: BoxDecoration(
              // A banded gutter rather than a flat grey stripe: the header is
              // the seam between two hunks, so it gets a hairline top and bottom
              // and a shallow gradient that reads as a recess in the listing.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: focused
                    ? [
                        MacosColors.systemBlueColor.withValues(alpha: 0.26),
                        MacosColors.systemBlueColor.withValues(alpha: 0.16),
                      ]
                    : [
                        MacosColors.systemGrayColor.withValues(alpha: 0.14),
                        MacosColors.systemGrayColor.withValues(alpha: 0.07),
                      ],
              ),
              border: Border.symmetric(
                horizontal: BorderSide(
                  color: (focused
                          ? MacosColors.systemBlueColor
                          : MacosColors.systemGrayColor)
                      .withValues(alpha: 0.18),
                  width: 0.5,
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(kDiffHPad, 4, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    hunk.header,
                    style: kDiffMono.copyWith(color: kDiffHunkHeaderColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.staged)
                  DiffActionButton(
                    label: 'Unstage',
                    icon: CupertinoIcons.minus,
                    onPressed: () =>
                        widget.onAction(file, hunk, HunkAction.unstage),
                  )
                else ...[
                  DiffActionButton(
                    label: 'Stage',
                    icon: CupertinoIcons.plus,
                    onPressed: () =>
                        widget.onAction(file, hunk, HunkAction.stage),
                  ),
                  const SizedBox(width: 6),
                  DiffActionButton(
                    label: 'Discard',
                    icon: CupertinoIcons.arrow_uturn_left,
                    // Throws the hunk's work away — it gets the red, and the
                    // hover that says so before the click, not after.
                    tone: DiffActionTone.destructive,
                    onPressed: () =>
                        widget.onAction(file, hunk, HunkAction.discard),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(_LineItem line, Color defaultColor, double contentWidth) {
    // Full-width soft band (same as DiffView) so add/remove rows read as a
    // continuous gutter, not a tint that stops where the glyph run ends.
    return Container(
      width: contentWidth,
      color: diffLineBackground(line.text),
      padding: const EdgeInsets.symmetric(horizontal: kDiffHPad, vertical: 1),
      alignment: Alignment.centerLeft,
      child: Text(
        line.text,
        maxLines: 1,
        softWrap: false,
        strutStyle: kDiffStrut,
        style: kDiffMono.copyWith(
          color: diffLineColor(line.text, defaultColor),
        ),
      ),
    );
  }
}
