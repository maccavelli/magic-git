/// Syntax highlighting for the file viewer, built on `re_highlight`
/// (a Dart port of highlight.js).
///
/// The public surface here is deliberately **Flutter-free and isolate-safe**:
/// [highlightDoc] turns source into a compact [HighlightedLines] (per-line
/// backing text + run layout as typed arrays + interned scope names). No
/// `TextStyle`/`Color` appears, so the whole computation — the expensive part —
/// can run on the shared highlight worker isolate for large files (see
/// `highlight_worker.dart`), and only the cheap scope→`TextStyle` resolution
/// happens on the UI thread (in `code_view.dart`).
library;

import 'dart:typed_data';

import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// A styled run of source text: the substring [text] and the highlight.js
/// theme [scope] (e.g. `keyword`, `string`, `comment`) that colours it, or null
/// for un-scoped text. An internal intermediate emitted by the renderer before
/// runs are packed into the compact [HighlightedLines].
class HlRun {
  final String text;
  final String? scope;
  const HlRun(this.text, this.scope);
}

/// A syntax-highlighted document in a compact, isolate-cheap form.
///
/// The naive shape — one `List<HlRun>` per line — is a swarm of per-run
/// substring Strings and heap objects (roughly 8×N bytes of overhead for an
/// N-char file) retained for as long as a viewer window is open. Here each line
/// keeps a single backing String plus its run layout as parallel typed arrays,
/// and scope names are interned to small integer ids, so the retained cost
/// collapses to ~1×N plus a few typed arrays. Run substrings are materialized
/// lazily at paint, only for on-screen lines. Fully sendable across an isolate
/// boundary (Strings + typed data + ints), so the highlight worker returns it
/// directly.
class HighlightedLines {
  /// Interned scope names; a run's scope id indexes this list (or -1 = unscoped).
  final List<String?> scopes;
  final List<HighlightedLine> lines;
  const HighlightedLines(this.scopes, this.lines);

  int get length => lines.length;

  /// The scope name for a run's [scopeId], or null when unscoped (-1).
  String? scopeName(int scopeId) => scopeId < 0 ? null : scopes[scopeId];
}

/// One highlighted line: the full line [text] (no newline) plus its runs as
/// parallel arrays. For run `k`, its slice of [text] is
/// `[runStarts[k], runStarts[k + 1])` — so [runStarts] has one extra terminal
/// entry equal to `text.length` — and its scope is `runScopeIds[k]`, an index
/// into [HighlightedLines.scopes] (or -1 for unscoped).
class HighlightedLine {
  final String text;
  final Int32List runStarts;
  final Int32List runScopeIds;
  const HighlightedLine(this.text, this.runStarts, this.runScopeIds);

  int get runCount => runScopeIds.length;
}

/// Packs the renderer's flat runs into per-line [HighlightedLine]s, interning
/// scope names as it goes.
class _DocBuilder {
  final _scopeIds = <String, int>{};
  final _scopes = <String?>[];
  final _lines = <HighlightedLine>[];

  final _lineBuf = StringBuffer();
  var _lineLen = 0;
  List<int> _starts = <int>[0];
  List<int> _scopeOfRun = <int>[];

  int _intern(String? scope) {
    if (scope == null) return -1;
    return _scopeIds.putIfAbsent(scope, () {
      _scopes.add(scope);
      return _scopes.length - 1;
    });
  }

  void _addRun(String text, String? scope) {
    if (text.isEmpty) return;
    _lineBuf.write(text);
    _lineLen += text.length;
    _starts.add(_lineLen);
    _scopeOfRun.add(_intern(scope));
  }

  void _endLine() {
    _lines.add(
      HighlightedLine(
        _lineBuf.toString(),
        Int32List.fromList(_starts),
        Int32List.fromList(_scopeOfRun),
      ),
    );
    _lineBuf.clear();
    _lineLen = 0;
    _starts = <int>[0];
    _scopeOfRun = <int>[];
  }

  /// Adds [text] under [scope], breaking it on `\n` into the current and
  /// subsequent lines (N newlines → N+1 lines; a trailing newline yields a final
  /// empty line — how a text editor counts lines). Uses `indexOf` rather than
  /// `split` so it doesn't allocate an intermediate parts list.
  void feed(String text, String? scope) {
    var start = 0;
    while (true) {
      final nl = text.indexOf('\n', start);
      if (nl < 0) {
        _addRun(text.substring(start), scope);
        return;
      }
      _addRun(text.substring(start, nl), scope);
      _endLine();
      start = nl + 1;
    }
  }

  HighlightedLines finish() {
    _endLine();
    return HighlightedLines(_scopes, _lines);
  }
}

/// Individual lines longer than this are not highlighted (their whole file
/// falls back to plain if any line exceeds it): a single pathological line —
/// a minified bundle on one line — can drive highlight.js's regex engine into
/// catastrophic backtracking. VS Code disables tokenization past a comparable
/// per-line length for the same reason.
const int maxHighlightLineLength = 20000;

/// highlight.js language id → grammar. Exactly the ids [viewerFileTypeFor]
/// can emit; anything else is treated as plain text.
final Map<String, Mode> _languageModes = {
  'bash': langBash,
  'c': langC,
  'cmake': langCmake,
  'cpp': langCpp,
  'csharp': langCsharp,
  'css': langCss,
  'dart': langDart,
  'diff': langDiff,
  'dockerfile': langDockerfile,
  'go': langGo,
  'graphql': langGraphql,
  'groovy': langGroovy,
  'ini': langIni,
  'java': langJava,
  'javascript': langJavascript,
  'json': langJson,
  'kotlin': langKotlin,
  'less': langLess,
  'lua': langLua,
  'makefile': langMakefile,
  'markdown': langMarkdown,
  'objectivec': langObjectivec,
  'perl': langPerl,
  'php': langPhp,
  'properties': langProperties,
  'protobuf': langProtobuf,
  'python': langPython,
  'r': langR,
  'ruby': langRuby,
  'rust': langRust,
  'scala': langScala,
  'scss': langScss,
  'sql': langSql,
  'swift': langSwift,
  'typescript': langTypescript,
  'xml': langXml,
  'yaml': langYaml,
};

/// Lazily-built engine with every supported grammar registered. Lazy so an
/// isolate that highlights one file pays the registration cost once, in that
/// isolate, rather than at import time on the UI thread.
Highlight? _engine;
Highlight get _highlight => _engine ??= (Highlight()
  ..registerLanguages(_languageModes));

/// Whether [languageId] has a registered grammar.
bool isLanguageSupported(String? languageId) =>
    languageId != null && _languageModes.containsKey(languageId);

/// Highlights [code] as [languageId] into the compact [HighlightedLines] (one
/// entry per line, split on `\n`). Falls back to plain — i.e. [plainDoc] — when
/// the language is unknown, or when any single line is too long to tokenize
/// safely ([maxHighlightLineLength]).
///
/// Pure and Flutter-free: safe to run on the highlight worker isolate.
HighlightedLines highlightDoc(String code, String? languageId) {
  if (!isLanguageSupported(languageId) || _hasOverlongLine(code)) {
    return plainDoc(code);
  }
  final result = _highlight.highlight(
    code: code,
    language: languageId!,
    ignoreIllegals: true,
  );
  final renderer = _ScopeRunRenderer();
  result.render(renderer);
  final builder = _DocBuilder();
  for (final run in renderer.runs) {
    builder.feed(run.text, run.scope);
  }
  return builder.finish();
}

/// The un-highlighted form: every line as a single un-scoped run. Shared by the
/// plain-text path and used as the instant first render before an off-thread
/// highlight completes.
HighlightedLines plainDoc(String code) => (_DocBuilder()..feed(code, null)).finish();

bool _hasOverlongLine(String code) {
  var lineStart = 0;
  for (var i = 0; i < code.length; i++) {
    if (code.codeUnitAt(i) == 0x0A) {
      if (i - lineStart > maxHighlightLineLength) return true;
      lineStart = i + 1;
    }
  }
  return code.length - lineStart > maxHighlightLineLength;
}

/// Collapses `re_highlight`'s token tree into a flat run list, tagging each
/// text run with its innermost scope — mirroring how the package's own
/// `TextSpanRenderer` styles text (by the top-of-stack node's scope), but
/// emitting scope *names* instead of `TextStyle`s so the result stays
/// isolate-sendable.
class _ScopeRunRenderer implements HighlightRenderer {
  final List<HlRun> runs = [];
  final List<String?> _scopes = [];

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) => _scopes.removeLast();

  @override
  void addText(String text) {
    if (text.isEmpty) return;
    runs.add(HlRun(text, _scopes.isEmpty ? null : _scopes.last));
  }
}
