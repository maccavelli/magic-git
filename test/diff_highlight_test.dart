import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';
import 'package:remote_magic_git/features/common/diff_highlight.dart';
import 'package:remote_magic_git/features/common/diff_view.dart' show kDiffMono;
import 'package:remote_magic_git/features/viewer/code_view.dart'
    show codeThemeFor;

const _patch = '''
diff --git a/lib/foo.dart b/lib/foo.dart
index 1111111..2222222 100644
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -1,3 +1,3 @@
 class Foo {
-  final int value = 1;
+  final int value = 2;
 }
''';

/// Flattens a span tree to its concatenated text, so a rendered line can be
/// checked to still copy byte-for-byte.
String spanText(InlineSpan span) {
  final buf = StringBuffer();
  span.visitChildren((child) {
    if (child is TextSpan && child.text != null) buf.write(child.text);
    return true;
  });
  return buf.toString();
}

/// Every leaf TextSpan under [span].
List<TextSpan> leaves(InlineSpan span) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null && s.text!.isNotEmpty) out.add(s);
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  walk(span);
  return out;
}

void main() {
  final file = parseUnifiedDiff(_patch)!;

  group('computeDiffLineHighlights', () {
    test('classifies each body line and pairs the modified line', () {
      final h = computeDiffLineHighlights(file);
      // " class Foo {", "-  ...= 1;", "+  ...= 2;", " }"
      expect(h.length, 4);
      expect(h.map((e) => e.kind).toList(), [
        DiffLineKind.context,
        DiffLineKind.remove,
        DiffLineKind.add,
        DiffLineKind.context,
      ]);
      // The remove/add pair is intra-line diffed: the changed digit is marked
      // on both sides, and only that.
      expect(h[1].intraline, isNotEmpty);
      expect(h[2].intraline, isNotEmpty);
      // "1" and "2" occupy the same offset in "  final int value = X;".
      const content = '  final int value = 1;';
      final r = h[1].intraline.first;
      expect(content.substring(r.start, r.end), '1');
      // Unchanged context lines carry no intra-line emphasis.
      expect(h[0].intraline, isEmpty);
      expect(h[3].intraline, isEmpty);
    });

    test('produces syntax runs for a recognised (.dart) language', () {
      final h = computeDiffLineHighlights(file);
      // At least one content line resolves highlight runs (dart is supported).
      expect(h.any((e) => e.runs != null && e.runs!.isNotEmpty), isTrue);
    });

    test('skips syntax runs when highlighting is disabled (huge-diff path)', () {
      final h = computeDiffLineHighlights(file, enableHighlight: false);
      expect(h.every((e) => e.runs == null), isTrue);
      // …but intra-line emphasis still runs (it's cheap).
      expect(h[1].intraline, isNotEmpty);
    });
  });

  group('diffLineSpan', () {
    final theme = codeThemeFor(Brightness.dark);
    const defaultColor = Color(0xFFDDDDDD);

    test('keeps the full line text so a copy round-trips', () {
      const raw = '+  final int value = 2;';
      final h = computeDiffLineHighlights(file)[2];
      final span = diffLineSpan(raw, h, kDiffMono, defaultColor, theme);
      expect(spanText(span), raw);
    });

    test('emphasises the intra-line changed range with a background', () {
      const raw = '+  final int value = 2;';
      final h = computeDiffLineHighlights(file)[2];
      final span = diffLineSpan(raw, h, kDiffMono, defaultColor, theme);
      // Exactly the changed "2" run carries a background wash.
      final emphasised =
          leaves(span).where((s) => s.style?.backgroundColor != null).toList();
      expect(emphasised, isNotEmpty);
      expect(emphasised.map((s) => s.text).join(), contains('2'));
    });

    test('a line with no render data still shows marker + content', () {
      const raw = '+brand new line';
      final span = diffLineSpan(raw, null, kDiffMono, defaultColor, theme);
      expect(spanText(span), raw);
      // First leaf is the "+" marker.
      expect(leaves(span).first.text, '+');
    });
  });
}
