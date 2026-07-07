import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/viewer/syntax_highlighter.dart';

// The source text of a highlighted document, re-joined from its lines.
String _source(HighlightedLines doc) => doc.lines.map((l) => l.text).join('\n');

// Whether every run in the document is un-scoped (plain text).
bool _allPlain(HighlightedLines doc) => doc.lines.every(
      (l) => l.runScopeIds.every((id) => id < 0),
    );

void main() {
  group('plainDoc', () {
    test('splits on newlines: N newlines -> N+1 lines, each plain', () {
      final doc = plainDoc('a\nbb\nccc');
      expect(doc.length, 3);
      expect(doc.lines[0].text, 'a');
      expect(doc.lines[1].text, 'bb');
      expect(doc.lines[2].text, 'ccc');
      expect(_allPlain(doc), isTrue);
    });

    test('a trailing newline yields a final empty line', () {
      final doc = plainDoc('a\n');
      expect(doc.length, 2);
      expect(doc.lines[1].text, '');
      expect(doc.lines[1].runCount, 0);
    });

    test('empty input is a single empty line', () {
      final doc = plainDoc('');
      expect(doc.length, 1);
      expect(doc.lines[0].text, '');
      expect(doc.lines[0].runCount, 0);
    });
  });

  group('highlightDoc', () {
    test('supported language produces at least one scoped run', () {
      final doc = highlightDoc('class Foo {}\n', 'dart');
      // `class` is a keyword — some run must carry a real (non-negative) scope.
      final scoped = doc.lines
          .expand((l) => l.runScopeIds)
          .where((id) => id >= 0);
      expect(scoped, isNotEmpty);
      // Round-trips the source exactly (highlighting never drops characters).
      expect(_source(doc), 'class Foo {}\n');
    });

    test('interned scope ids resolve to real highlight.js scope names', () {
      final doc = highlightDoc('class Foo {}\n', 'dart');
      final names = <String?>{};
      for (final line in doc.lines) {
        for (final id in line.runScopeIds) {
          names.add(doc.scopeName(id));
        }
      }
      // At least one resolved scope name (e.g. 'keyword') is present.
      expect(names.where((n) => n != null), isNotEmpty);
    });

    test('preserves line structure while highlighting', () {
      const src = 'import "a";\nvoid main() {}\n';
      final doc = highlightDoc(src, 'dart');
      expect(doc.length, 3); // two lines + trailing empty
      expect(_source(doc), src);
    });

    test('unknown language falls back to plain (no scopes)', () {
      expect(_allPlain(highlightDoc('anything at all\n', 'no-such-lang')), isTrue);
    });

    test('null language is plain text', () {
      expect(_allPlain(highlightDoc('plain\ntext', null)), isTrue);
    });

    test('a line over the length cap forces the whole file to plain', () {
      final longLine = 'a' * (maxHighlightLineLength + 1);
      final doc = highlightDoc('class Foo {}\n$longLine', 'dart');
      expect(_allPlain(doc), isTrue);
    });

    test('run boundaries tile the line text exactly', () {
      final doc = highlightDoc('final x = 1;\n', 'dart');
      for (final line in doc.lines) {
        // runStarts has one terminal entry == text length; runs are contiguous
        // and cover the whole line.
        expect(line.runStarts.first, 0);
        expect(line.runStarts.last, line.text.length);
        expect(line.runStarts.length, line.runCount + 1);
        final rebuilt = StringBuffer();
        for (var k = 0; k < line.runCount; k++) {
          rebuilt.write(line.text.substring(line.runStarts[k], line.runStarts[k + 1]));
        }
        expect(rebuilt.toString(), line.text);
      }
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
