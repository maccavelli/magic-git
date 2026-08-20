// The flat DiffView (the read-only fallback for stash/recovery/untracked/file-
// history) now syntax-highlights content lines per file, headers left plain.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/diff_view.dart';

const _patch =
    'diff --git a/lib/foo.dart b/lib/foo.dart\n'
    'index 111..222 100644\n'
    '--- a/lib/foo.dart\n'
    '+++ b/lib/foo.dart\n'
    '@@ -1,3 +1,3 @@\n'
    ' class Foo {\n'
    '-  final int value = 1;\n'
    '+  final int value = 2;\n'
    ' }\n';

List<Color> _leafColors(WidgetTester tester) {
  final colors = <Color>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if ((s.text?.isNotEmpty ?? false) && s.style?.color != null) {
        colors.add(s.style!.color!);
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rt.text);
  }
  return colors;
}

Future<void> _pump(WidgetTester tester, String diff) async {
  await tester.binding.setSurfaceSize(const Size(900, 600));
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(height: 600, child: DiffView(diff: diff)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('content lines carry more than one syntax colour', (
    tester,
  ) async {
    await _pump(tester, _patch);
    expect(_leafColors(tester).toSet().length, greaterThan(1));
    // Text is preserved.
    expect(find.textContaining('final int value = 2;'), findsOneWidget);
  });

  testWidgets('a diff with no file headers still renders (plain fallback)', (
    tester,
  ) async {
    // No `diff --git` line → highlighting is skipped, but the text still shows.
    await _pump(tester, 'just some text\nwith two lines\n');
    expect(find.textContaining('just some text'), findsOneWidget);
  });
}
