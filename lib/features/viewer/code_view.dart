import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';
import '../common/diff_view.dart' show kDiffMono;
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import 'file_content.dart';
import 'highlight_worker.dart';
import 'syntax_highlighter.dart';

/// A resolved code colour theme: highlight.js scope → [TextStyle], plus the
/// editor background/foreground pulled from the theme's `root` entry.
class CodeTheme {
  final Map<String, TextStyle> styles;
  final Color background;
  final Color foreground;

  const CodeTheme({
    required this.styles,
    required this.background,
    required this.foreground,
  });

  factory CodeTheme._from(
    Map<String, TextStyle> raw, {
    required Color fallbackBg,
    required Color fallbackFg,
  }) {
    final root = raw['root'];
    return CodeTheme(
      styles: raw,
      background: root?.backgroundColor ?? fallbackBg,
      foreground: root?.color ?? fallbackFg,
    );
  }
}

/// Atom One Dark on dark, GitHub light on light — both ship with `re_highlight`
/// and match this app's overall macOS look.
CodeTheme codeThemeFor(Brightness brightness) => brightness == Brightness.dark
    ? CodeTheme._from(
        atomOneDarkTheme,
        fallbackBg: const Color(0xFF282C34),
        fallbackFg: const Color(0xFFABB2BF),
      )
    : CodeTheme._from(
        githubTheme,
        fallbackBg: const Color(0xFFFFFFFF),
        fallbackFg: const Color(0xFF24292E),
      );

/// Builds the [TextSpan] for one highlighted [line], resolving each run's scope
/// (via the document's interned [scopes] table) to a [TextStyle] merged over
/// [base] — so the mono font/size survive and only colour/weight/italic come
/// from the theme. Run substrings are cut from the line's backing text lazily
/// here, at paint, only for on-screen lines. Guards against a pathological
/// single line by truncating the rendered text at [maxHighlightLineLength] —
/// the underlying file is untouched (open it externally for the full line).
TextSpan lineToSpan(
  HighlightedLine line,
  List<String?> scopes,
  CodeTheme theme,
  TextStyle base,
) {
  final text = line.text;
  if (text.isEmpty) return TextSpan(text: '', style: base);
  final starts = line.runStarts;
  final scopeIds = line.runScopeIds;
  final children = <TextSpan>[];
  var used = 0;
  var truncated = false;
  for (var k = 0; k < scopeIds.length; k++) {
    if (used >= maxHighlightLineLength) {
      truncated = true;
      break;
    }
    final runStart = starts[k];
    var runEnd = starts[k + 1];
    if (used + (runEnd - runStart) > maxHighlightLineLength) {
      var cut = maxHighlightLineLength - used;
      // Don't slice through a surrogate pair — a dangling high surrogate would
      // render as a replacement box right before the truncation marker.
      if (cut > 0 && cut < runEnd - runStart) {
        final unit = text.codeUnitAt(runStart + cut - 1);
        if (unit >= 0xD800 && unit <= 0xDBFF) cut -= 1;
      }
      runEnd = runStart + cut;
      truncated = true;
    }
    used += runEnd - runStart;
    final scope = scopeIds[k] < 0 ? null : scopes[scopeIds[k]];
    children.add(
      TextSpan(
        text: text.substring(runStart, runEnd),
        style: scope == null ? base : base.merge(theme.styles[scope]),
      ),
    );
  }
  if (truncated) {
    children.add(
      TextSpan(
        text: '  … ⟨line truncated⟩',
        style: base.copyWith(
          color: MacosColors.systemGrayColor,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
  return TextSpan(children: children, style: base);
}

/// A read-only, syntax-highlighted source view.
///
/// Virtualized by line: lines render lazily through a `ListView.builder`, so
/// only the on-screen ones lay out — render cost is bounded by the viewport,
/// not the file. Highlighting runs inline for small files and on a background
/// isolate for large ones (per [FileContent.highlightOffMainThread]), showing
/// plain text instantly and swapping in colour when the isolate returns.
///
/// Wrapped in a `SelectionArea` for cross-line text selection; the line-number
/// gutter is excluded from selection so copied text is pure source. When
/// [wrap] is false, long lines scroll horizontally instead of wrapping.
class CodeView extends StatefulWidget {
  final FileContent content;

  /// highlight.js language id (from `viewerFileTypeFor`), or null for plain.
  final String? languageId;

  /// Word wrap. When false (default), long lines scroll horizontally.
  final bool wrap;

  /// Ticks to open (or re-focus) the in-file find bar — the viewer bumps this
  /// on ⌘F. Null when find isn't offered (e.g. a rendered preview).
  final Listenable? findSignal;

  /// Where focus goes when the find bar closes — the owning viewer window's
  /// focus node. Without this, closing find drops focus on the enclosing
  /// scope *above* the window's shortcut bindings, leaving ⌘W/⌘F dead until
  /// the user clicks back inside.
  final FocusNode? returnFocus;

  const CodeView({
    super.key,
    required this.content,
    required this.languageId,
    this.wrap = false,
    this.findSignal,
    this.returnFocus,
  });

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  final _vCtrl = ScrollController();
  final _hCtrl = ScrollController();

  // In-file find (⌘F): a bar above the source with match navigation. Matches
  // are whole lines that contain the query (case-insensitive) — simple, and the
  // useful "jump between the lines mentioning X" behaviour.
  final _findCtrl = TextEditingController();
  final _findFocus = FocusNode();
  bool _findOpen = false;
  List<int> _matchLines = const [];
  int _matchIdx = -1;

  HighlightedLines _doc = const HighlightedLines([], []);
  // Memoized pixel width of the widest line (no-wrap mode). Measuring it runs
  // a TextPainter layout over a line of up to maxHighlightLineLength chars —
  // done in build, that re-ran on every frame of a window drag/resize.
  // Invalidated when the doc or the theme brightness changes.
  double? _widestW;
  Brightness? _widestWFor;
  // Registered while the find bar is open: Escape closes find (and only
  // find), via the same registry the floating windows use — LIFO, so find
  // (opened later) wins over the window's own Escape-to-close.
  VoidCallback? _unregisterFindEscape;
  // Index of the line with the most code units — measured for its true pixel
  // width in `build` to size the horizontal scroll extent (so CJK/tab-heavy
  // lines, which a char-count estimate under-measures, are fully reachable).
  int _widestLineIndex = 0;
  // Bumped on every recompute so a slow isolate result for a superseded file
  // (the same widget reused for another path) is dropped.
  int _highlightToken = 0;

  // Monospace metrics depend only on the (constant) mono font, not colour, so
  // they're measured once and cached rather than re-laid-out on every build.
  late final double _charW =
      (TextPainter(
        text: TextSpan(text: '0' * 50, style: kDiffMono),
        textDirection: TextDirection.ltr,
      )..layout()).width /
      50;
  late final double _lineH = (TextPainter(
    text: const TextSpan(text: 'Xg', style: kDiffMono),
    textDirection: TextDirection.ltr,
  )..layout()).height;

  @override
  void initState() {
    super.initState();
    widget.findSignal?.addListener(_openFind);
    _recompute();
  }

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    if (old.findSignal != widget.findSignal) {
      old.findSignal?.removeListener(_openFind);
      widget.findSignal?.addListener(_openFind);
    }
    if (old.content.text != widget.content.text ||
        old.languageId != widget.languageId) {
      _recompute();
      // The file changed under an open find bar — re-run the query against it.
      if (_findOpen) _recomputeMatches(_findCtrl.text);
    }
  }

  @override
  void dispose() {
    _unregisterFindEscape?.call();
    widget.findSignal?.removeListener(_openFind);
    _findCtrl.dispose();
    _findFocus.dispose();
    _vCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  // ---- Find ----------------------------------------------------------------

  void _openFind() {
    _unregisterFindEscape ??= EscapeDismissRegistry.register(() {
      _closeFind();
      return true;
    });
    setState(() => _findOpen = true);
    _findFocus.requestFocus();
    // Select any existing query so typing replaces it, matching a browser's ⌘F.
    _findCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findCtrl.text.length,
    );
    if (_findCtrl.text.isNotEmpty) _recomputeMatches(_findCtrl.text);
  }

  void _closeFind() {
    _unregisterFindEscape?.call();
    _unregisterFindEscape = null;
    setState(() {
      _findOpen = false;
      _matchLines = const [];
      _matchIdx = -1;
    });
    // Hand focus back to the owning window so its shortcuts stay live.
    widget.returnFocus?.requestFocus();
  }

  void _recomputeMatches(String query) {
    final q = query.toLowerCase();
    final matches = <int>[];
    if (q.isNotEmpty) {
      for (var i = 0; i < _doc.lines.length; i++) {
        if (_doc.lines[i].text.toLowerCase().contains(q)) matches.add(i);
      }
    }
    setState(() {
      _matchLines = matches;
      _matchIdx = matches.isEmpty ? -1 : 0;
    });
    _scrollToMatch();
  }

  // Dart's `%` returns a non-negative result for a positive divisor, so this
  // wraps correctly in both directions.
  void _step(int dir) {
    if (_matchLines.isEmpty) return;
    setState(() => _matchIdx = (_matchIdx + dir) % _matchLines.length);
    _scrollToMatch();
  }

  void _scrollToMatch() {
    if (_matchIdx < 0 || !_vCtrl.hasClients) return;
    // Line offset is exact in the default no-wrap mode (fixed itemExtent); in
    // wrap mode it's approximate, which is fine for "bring it into view".
    final line = _matchLines[_matchIdx];
    final max = _vCtrl.position.maxScrollExtent;
    final offset = (line * _lineH - _lineH * 3).clamp(0.0, max).toDouble();
    _vCtrl.jumpTo(offset);
  }

  void _recompute() {
    final text = widget.content.text;
    final lang = widget.languageId;
    final token = ++_highlightToken;

    // Instant first paint as plain text; colour arrives synchronously (small)
    // or from the shared worker isolate (large).
    _setDoc(plainDoc(text));
    if (!isLanguageSupported(lang)) return;

    if (!widget.content.highlightOffMainThread) {
      _setDoc(highlightDoc(text, lang));
    } else {
      // Large file: highlight on the shared, long-lived worker isolate (grammars
      // registered once, not per file) rather than spawning a fresh isolate each
      // time. The token guard drops a result superseded by a newer file.
      highlightWorker
          .highlight(text, lang)
          .then((doc) {
            if (mounted && token == _highlightToken) {
              setState(() => _setDoc(doc));
            }
          })
          .catchError((_) {
            // Highlighting failed off-thread (e.g. malformed input the grammar
            // still choked on, or the worker died); the plain-text render set above
            // stays in place rather than surfacing as an unhandled async error.
          });
    }
  }

  void _setDoc(HighlightedLines doc) {
    _doc = doc;
    _widestW = null;
    var maxChars = 0;
    var widest = 0;
    for (var li = 0; li < doc.lines.length; li++) {
      final n = doc.lines[li].text.length;
      if (n > maxChars) {
        maxChars = n;
        widest = li;
      }
    }
    _widestLineIndex = widest;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = MacosTheme.brightnessOf(context);
    final theme = codeThemeFor(brightness);
    final base = kDiffMono.copyWith(color: theme.foreground);
    final charW = _charW;
    final lineH = _lineH;
    final gutterDigits = _doc.length.toString().length;
    final gutterW = gutterDigits * charW + 20; // digits + padding both sides

    final currentMatch = _matchIdx >= 0 ? _matchLines[_matchIdx] : -1;

    return ColoredBox(
      color: theme.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_findOpen) _findBar(context, theme),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final list = ListView.builder(
                  controller: _vCtrl,
                  primary: false,
                  // Fixed row height only when every line is exactly one row; a
                  // wrapped line spans several, so extent must be measured then.
                  itemExtent: widget.wrap ? null : lineH,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _doc.length,
                  itemBuilder: (context, i) =>
                      _row(i, base, theme, gutterW, lineH, i == currentMatch),
                );

                if (widget.wrap) {
                  return SelectionArea(child: list);
                }

                // No-wrap: one synchronized horizontal scroll over content at least
                // as wide as the longest line, so every row scrolls together. Measure
                // the widest line's true pixel width (not chars × charW), so tabs and
                // wide/CJK glyphs don't leave the tail unreachable off the right
                // edge. Memoized per (doc, brightness) — the measurement is O(widest
                // line) and build runs on every frame of a window drag.
                if (_widestW == null || _widestWFor != brightness) {
                  _widestW = _doc.lines.isEmpty
                      ? 0.0
                      : (TextPainter(
                          text: lineToSpan(
                            _doc.lines[_widestLineIndex],
                            _doc.scopes,
                            theme,
                            base,
                          ),
                          textDirection: TextDirection.ltr,
                          maxLines: 1,
                        )..layout()).width;
                  _widestWFor = brightness;
                }
                final widestW = _widestW!;
                final contentW = (gutterW + 8 + widestW + 24)
                    .clamp(constraints.maxWidth, double.infinity)
                    .toDouble();
                return MacosScrollbar(
                  controller: _hCtrl,
                  child: SingleChildScrollView(
                    controller: _hCtrl,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentW,
                      child: SelectionArea(child: list),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _findBar(BuildContext context, CodeTheme theme) {
    final total = _matchLines.length;
    final counter = _findCtrl.text.isEmpty
        ? ''
        : total == 0
        ? 'No results'
        : '${_matchIdx + 1} of $total';
    // Escape isn't bound here: closing find is registered with
    // EscapeDismissRegistry while the bar is open, so it works no matter what
    // holds focus (and takes priority over the window's Escape-to-close).
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            _step(-1),
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: theme.background,
          border: const Border(
            bottom: BorderSide(color: MacosColors.separatorColor),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: _findCtrl,
                focusNode: _findFocus,
                placeholder: 'Find in file',
                placeholderStyle: kAppPlaceholderStyle,
                onChanged: _recomputeMatches,
                onSubmitted: (_) => _step(1),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 72,
              child: Text(
                counter,
                style: MacosTheme.of(context).typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            const SizedBox(width: 4),
            MacosIconButton(
              icon: const MacosIcon(CupertinoIcons.chevron_up, size: 14),
              boxConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              // Canonical cursor policy (common/buttons.dart): hand when
              // there are matches to step through.
              mouseCursor: total == 0
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              onPressed: total == 0 ? null : () => _step(-1),
            ),
            MacosIconButton(
              icon: const MacosIcon(CupertinoIcons.chevron_down, size: 14),
              boxConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              mouseCursor: total == 0
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              onPressed: total == 0 ? null : () => _step(1),
            ),
            MacosIconButton(
              icon: const MacosIcon(CupertinoIcons.xmark, size: 14),
              boxConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              mouseCursor: SystemMouseCursors.click,
              onPressed: _closeFind,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    int i,
    TextStyle base,
    CodeTheme theme,
    double gutterW,
    double lineH,
    bool isCurrentMatch,
  ) {
    final gutterStyle = base.copyWith(
      color: theme.foreground.withValues(alpha: 0.4),
    );
    return ColoredBox(
      color: isCurrentMatch
          ? MacosColors.systemYellowColor.withValues(alpha: 0.28)
          : const Color(0x00000000),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line numbers are chrome, not content — exclude them from selection
          // so a copy yields pure source.
          SelectionContainer.disabled(
            child: SizedBox(
              width: gutterW,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '${i + 1}',
                  textAlign: TextAlign.right,
                  style: gutterStyle,
                  maxLines: 1,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              lineToSpan(_doc.lines[i], _doc.scopes, theme, base),
              softWrap: widget.wrap,
              overflow: widget.wrap ? TextOverflow.clip : TextOverflow.visible,
            ),
          ),
        ],
      ),
    );
  }
}
