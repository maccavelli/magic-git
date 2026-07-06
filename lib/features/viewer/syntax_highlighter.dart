/// Syntax highlighting for the file viewer, built on `re_highlight`
/// (a Dart port of highlight.js).
///
/// The public surface here is deliberately **Flutter-free and isolate-safe**:
/// [highlightLines] turns source into a list of lines, each a list of
/// [HlRun]s (`text` + theme `scope`). No `TextStyle`/`Color` appears, so the
/// whole computation — the expensive part — can be handed to `Isolate.run`
/// for large files (see `CodeView`), and only the cheap scope→`TextStyle`
/// resolution happens on the UI thread (in `code_view.dart`).
library;

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
/// theme [scope] (e.g. `keyword`, `string`, `comment`) that colours it, or
/// null for un-scoped text. Kept to plain fields (String + String?) so a
/// `List<List<HlRun>>` is trivially sendable across an isolate boundary.
class HlRun {
  final String text;
  final String? scope;
  const HlRun(this.text, this.scope);
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

/// Highlights [code] as [languageId], returning one entry per line (split on
/// `\n`), each a list of styled [HlRun]s. Falls back to a single un-scoped run
/// per line — i.e. [plainLines] — when the language is unknown, or when any
/// single line is too long to tokenize safely ([maxHighlightLineLength]).
///
/// Pure and Flutter-free: safe to call inside `Isolate.run`.
List<List<HlRun>> highlightLines(String code, String? languageId) {
  if (!isLanguageSupported(languageId) || _hasOverlongLine(code)) {
    return plainLines(code);
  }
  final result = _highlight.highlight(
    code: code,
    language: languageId!,
    ignoreIllegals: true,
  );
  final renderer = _ScopeRunRenderer();
  result.render(renderer);
  return _splitIntoLines(renderer.runs);
}

/// The un-highlighted form: every line as a single un-scoped run. Shared by
/// the plain-text path and used as the instant first render before an
/// off-thread highlight completes.
List<List<HlRun>> plainLines(String code) => _splitIntoLines([HlRun(code, null)]);

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

/// Splits a flat run list into per-line run lists, breaking runs on `\n`. N
/// newlines yield N+1 lines (a trailing newline produces a final empty line),
/// matching how a text editor counts lines.
List<List<HlRun>> _splitIntoLines(List<HlRun> runs) {
  final lines = <List<HlRun>>[];
  var current = <HlRun>[];
  for (final run in runs) {
    final parts = run.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        lines.add(current);
        current = <HlRun>[];
      }
      if (parts[i].isNotEmpty) current.add(HlRun(parts[i], run.scope));
    }
  }
  lines.add(current);
  return lines;
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
