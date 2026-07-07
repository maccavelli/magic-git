// The shared long-lived highlight worker isolate: it highlights on a persistent
// isolate (grammars registered once) and returns the same per-line runs the
// inline path would. Isolate.spawn of a top-level entry point works in
// flutter_test (unlike Isolate.run, whose closure captures the test zone).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/viewer/highlight_worker.dart';
import 'package:remote_magic_git/features/viewer/syntax_highlighter.dart';

// The document's source text, re-joined from its per-line backing strings.
String _flatten(HighlightedLines doc) => doc.lines.map((l) => l.text).join('\n');

void main() {
  late HighlightWorker worker;

  setUp(() => worker = HighlightWorker());
  tearDown(() => worker.dispose());

  test('highlights on the worker and preserves the source text exactly', () async {
    const code = 'void main() {\n  print("hi");\n}\n';
    final doc = await worker.highlight(code, 'dart');
    // Round-trips the source (one entry per line incl. the trailing empty line).
    expect(_flatten(doc), code);
    // Highlighting actually ran: a Dart keyword got a scope somewhere.
    final scoped = doc.lines.expand((l) => l.runScopeIds).where((id) => id >= 0);
    expect(scoped, isNotEmpty);
  });

  test('matches the inline highlightDoc result', () async {
    const code = 'final x = 1;\nString s = "y";\n';
    final fromWorker = await worker.highlight(code, 'dart');
    final inline = highlightDoc(code, 'dart');
    expect(_flatten(fromWorker), _flatten(inline));
    expect(fromWorker.length, inline.length);
  });

  test('serves many requests on the one warm isolate', () async {
    final results = await Future.wait([
      for (var i = 0; i < 8; i++) worker.highlight('final v$i = $i;\n', 'dart'),
    ]);
    for (var i = 0; i < 8; i++) {
      expect(_flatten(results[i]), 'final v$i = $i;\n');
    }
  });

  test('unknown language falls back to plain lines (no scopes)', () async {
    const code = 'just some plain text\nsecond line\n';
    final doc = await worker.highlight(code, null);
    expect(_flatten(doc), code);
    expect(
      doc.lines.every((l) => l.runScopeIds.every((id) => id < 0)),
      isTrue,
    );
  });

  test('respawns after dispose (worker is reusable)', () async {
    await worker.highlight('final a = 1;\n', 'dart');
    worker.dispose();
    // A fresh highlight after dispose lazily respawns the isolate.
    final lines = await worker.highlight('final b = 2;\n', 'dart');
    expect(_flatten(lines), 'final b = 2;\n');
  });
}
