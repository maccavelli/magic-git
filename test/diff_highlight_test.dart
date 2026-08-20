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
    test('classifies each body line', () {
      final h = computeDiffLineHighlights(file);
      // " class Foo {", "-  ...= 1;", "+  ...= 2;", " }"
      expect(h.length, 4);
      expect(h.map((e) => e.kind).toList(), [
        DiffLineKind.context,
        DiffLineKind.remove,
        DiffLineKind.add,
        DiffLineKind.context,
      ]);
    });

    test('produces syntax runs for a recognised (.dart) language', () {
      final h = computeDiffLineHighlights(file);
      // At least one content line resolves highlight runs (dart is supported).
      expect(h.any((e) => e.runs != null && e.runs!.isNotEmpty), isTrue);
    });

    test(
      'skips syntax runs when highlighting is disabled (huge-diff path)',
      () {
        final h = computeDiffLineHighlights(file, enableHighlight: false);
        expect(h.every((e) => e.runs == null), isTrue);
      },
    );
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

    test(
      'never paints per-character backgrounds — the add/remove colour lives '
      'in the glyphs and the full-row band, same as the History patch view',
      () {
        final highlights = computeDiffLineHighlights(file);
        final raws =
            ' class Foo {\n-  final int value = 1;\n'
                    '+  final int value = 2;\n }'
                .split('\n');
        for (var i = 0; i < raws.length; i++) {
          final span = diffLineSpan(
            raws[i],
            highlights[i],
            kDiffMono,
            defaultColor,
            theme,
          );
          for (final leaf in leaves(span)) {
            expect(
              leaf.style?.backgroundColor,
              isNull,
              reason:
                  'leaf "${leaf.text}" of "${raws[i]}" carries a background '
                  'wash — diff text must colour only its glyphs',
            );
          }
        }
      },
    );

    test('a line with no render data still shows marker + content', () {
      const raw = '+brand new line';
      final span = diffLineSpan(raw, null, kDiffMono, defaultColor, theme);
      expect(spanText(span), raw);
      // First leaf is the "+" marker.
      expect(leaves(span).first.text, '+');
    });
  });
}
