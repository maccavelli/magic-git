import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/viewer/syntax_highlighter.dart';

// Total text of a line, re-joined from its runs.
String _lineText(List<HlRun> line) => line.map((r) => r.text).join();

void main() {
  group('plainLines', () {
    test('splits on newlines: N newlines -> N+1 lines, each one plain run', () {
      final lines = plainLines('a\nbb\nccc');
      expect(lines.length, 3);
      expect(_lineText(lines[0]), 'a');
      expect(_lineText(lines[1]), 'bb');
      expect(_lineText(lines[2]), 'ccc');
      // Every run is un-scoped in plain text.
      expect(lines.expand((l) => l).every((r) => r.scope == null), isTrue);
    });

    test('a trailing newline yields a final empty line', () {
      final lines = plainLines('a\n');
      expect(lines.length, 2);
      expect(lines[1], isEmpty);
    });

    test('empty input is a single empty line', () {
      expect(plainLines(''), [<HlRun>[]]);
    });
  });

  group('highlightLines', () {
    test('supported language produces at least one scoped run', () {
      final lines = highlightLines('class Foo {}\n', 'dart');
      final scopes = lines.expand((l) => l).map((r) => r.scope).toSet();
      // `class` is a keyword — some run must carry a non-null scope.
      expect(scopes.any((s) => s != null), isTrue);
      // Round-trips the source exactly (highlighting never drops characters).
      expect(lines.map(_lineText).join('\n'), 'class Foo {}\n');
    });

    test('preserves line structure while highlighting', () {
      const src = 'import "a";\nvoid main() {}\n';
      final lines = highlightLines(src, 'dart');
      expect(lines.length, 3); // two lines + trailing empty
      expect(lines.map(_lineText).join('\n'), src);
    });

    test('unknown language falls back to plain (no scopes)', () {
      final lines = highlightLines('anything at all\n', 'no-such-lang');
      expect(lines.expand((l) => l).every((r) => r.scope == null), isTrue);
    });

    test('null language is plain text', () {
      final lines = highlightLines('plain\ntext', null);
      expect(lines.expand((l) => l).every((r) => r.scope == null), isTrue);
    });

    test('a line over the length cap forces the whole file to plain', () {
      final longLine = 'a' * (maxHighlightLineLength + 1);
      final lines = highlightLines('class Foo {}\n$longLine', 'dart');
      expect(lines.expand((l) => l).every((r) => r.scope == null), isTrue);
    });
  });

  group('isLanguageSupported', () {
    test('known ids are supported, unknown/null are not', () {
      expect(isLanguageSupported('dart'), isTrue);
      expect(isLanguageSupported('yaml'), isTrue);
      expect(isLanguageSupported('xml'), isTrue);
      expect(isLanguageSupported('no-such-lang'), isFalse);
      expect(isLanguageSupported(null), isFalse);
    });
  });
}
