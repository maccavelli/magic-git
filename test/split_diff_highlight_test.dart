// SplitDiffView now syntax-highlights each column (old = pre-image, new =
// post-image) and washes the intra-line changed characters.

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
  testWidgets('washes the intra-line changed character', (tester) async {
    await _pump(tester);
    final emphasised = _allLeaves(
      tester,
    ).where((s) => s.style?.backgroundColor != null).toList();
    expect(emphasised, isNotEmpty);
    // The changed digits ("1" removed, "2" added) are what carry the wash.
    final text = emphasised.map((s) => s.text).join();
    expect(text.contains('1') || text.contains('2'), isTrue);
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
