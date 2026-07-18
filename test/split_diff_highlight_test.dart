// SplitDiffView syntax-highlights each column (old = pre-image, new =
// post-image) with the same canonical formatting as every other diff surface:
// colour lives in the glyphs and the row-level band only — no per-character
// background washes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/split_diff_view.dart';

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

List<TextSpan> _allLeaves(WidgetTester tester) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null && s.text!.isNotEmpty) out.add(s);
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rt.text);
  }
  return out;
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const MacosApp(
      home: MacosWindow(
        child: ContentArea(
          builder: _builder,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _builder(BuildContext context, ScrollController _) =>
    const SizedBox(width: 900, height: 400, child: SplitDiffView(diff: _patch));

void main() {
  testWidgets('never paints per-character backgrounds', (tester) async {
    await _pump(tester);
    final washed = _allLeaves(
      tester,
    ).where((s) => s.style?.backgroundColor != null).toList();
    // Add/remove colour comes from the cell band and the glyph colours; a
    // character-level wash on top made the text hard to read.
    expect(washed, isEmpty);
  });

  testWidgets('applies more than one syntax colour', (tester) async {
    await _pump(tester);
    final colors = _allLeaves(tester)
        .map((s) => s.style?.color)
        .whereType<Color>()
        .toSet();
    // A recognised .dart file yields several distinct token colours, not one
    // flat green/red.
    expect(colors.length, greaterThan(1));
  });
}
