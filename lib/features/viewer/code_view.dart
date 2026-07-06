import 'dart:isolate';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:macos_ui/macos_ui.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';
import '../common/diff_view.dart' show kDiffMono;
import 'file_content.dart';
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

/// Builds the [TextSpan] for one highlighted line, resolving each run's scope
/// to a [TextStyle] merged over [base] (so the mono font/size survive and only
/// colour/weight/italic come from the theme). Guards against a pathological
/// single line by truncating the rendered text at [maxHighlightLineLength] —
/// the underlying file is untouched (open it externally for the full line).
TextSpan lineToSpan(List<HlRun> line, CodeTheme theme, TextStyle base) {
  if (line.isEmpty) return TextSpan(text: '', style: base);
  final children = <TextSpan>[];
  var used = 0;
  var truncated = false;
  for (final run in line) {
    if (used >= maxHighlightLineLength) {
      truncated = true;
      break;
    }
    var text = run.text;
    if (used + text.length > maxHighlightLineLength) {
      text = text.substring(0, maxHighlightLineLength - used);
      truncated = true;
    }
    used += text.length;
    children.add(
      TextSpan(
        text: text,
        style: run.scope == null ? base : base.merge(theme.styles[run.scope!]),
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

  const CodeView({
    super.key,
    required this.content,
    required this.languageId,
    this.wrap = false,
  });

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  final _vCtrl = ScrollController();
  final _hCtrl = ScrollController();

  List<List<HlRun>> _lines = const [];
  int _maxLineChars = 0;
  // Bumped on every recompute so a slow isolate result for a superseded file
  // (the same widget reused for another path) is dropped.
  int _highlightToken = 0;

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    if (old.content.text != widget.content.text ||
        old.languageId != widget.languageId) {
      _recompute();
    }
  }

  @override
  void dispose() {
    _vCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  void _recompute() {
    final text = widget.content.text;
    final lang = widget.languageId;
    final token = ++_highlightToken;

    // Instant first paint as plain text; colour arrives synchronously (small)
    // or from an isolate (large).
    _setLines(plainLines(text));
    if (!isLanguageSupported(lang)) return;

    if (!widget.content.highlightOffMainThread) {
      _setLines(highlightLines(text, lang));
    } else {
      Isolate.run(() => highlightLines(text, lang)).then((lines) {
        if (mounted && token == _highlightToken) setState(() => _setLines(lines));
      });
    }
  }

  void _setLines(List<List<HlRun>> lines) {
    _lines = lines;
    var maxChars = 0;
    for (final line in lines) {
      var n = 0;
      for (final run in line) {
        n += run.text.length;
      }
      if (n > maxChars) maxChars = n;
    }
    _maxLineChars = maxChars;
  }

  // Monospace metrics, measured once per (fontSize) via a throwaway painter.
  double _charWidth(TextStyle base) {
    final tp = TextPainter(
      text: TextSpan(text: '0' * 50, style: base),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width / 50;
  }

  double _lineHeight(TextStyle base) {
    final tp = TextPainter(
      text: TextSpan(text: 'Xg', style: base),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.height;
  }

  @override
  Widget build(BuildContext context) {
    final theme = codeThemeFor(MacosTheme.brightnessOf(context));
    final base = kDiffMono.copyWith(color: theme.foreground);
    final charW = _charWidth(base);
    final lineH = _lineHeight(base);
    final gutterDigits = _lines.length.toString().length;
    final gutterW = gutterDigits * charW + 20; // digits + padding both sides

    return ColoredBox(
      color: theme.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final list = ListView.builder(
            controller: _vCtrl,
            primary: false,
            // Fixed row height only when every line is exactly one row; a
            // wrapped line spans several, so extent must be measured then.
            itemExtent: widget.wrap ? null : lineH,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: _lines.length,
            itemBuilder: (context, i) =>
                _row(i, base, theme, gutterW, lineH),
          );

          if (widget.wrap) {
            return SelectionArea(child: list);
          }

          // No-wrap: one synchronized horizontal scroll over content at least
          // as wide as the longest line, so every row scrolls together.
          final contentW = (gutterW + 8 + _maxLineChars * charW + 24)
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
    );
  }

  Widget _row(
    int i,
    TextStyle base,
    CodeTheme theme,
    double gutterW,
    double lineH,
  ) {
    final gutterStyle = base.copyWith(
      color: theme.foreground.withValues(alpha: 0.4),
    );
    return Row(
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
            lineToSpan(_lines[i], theme, base),
            softWrap: widget.wrap,
            overflow: widget.wrap ? TextOverflow.clip : TextOverflow.visible,
          ),
        ),
      ],
    );
  }
}
