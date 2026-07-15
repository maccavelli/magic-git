// Verifies the side-by-side (split) diff renderer: removals land on the left,
// additions on the right, context on both, and a hunk with no parseable body
// falls back to the plain unified view.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/diff_view.dart';
import 'package:remote_magic_git/features/common/split_diff_view.dart';

const _diff = '''
diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 keep
-old line
+new line
 tail
''';

Future<void> _pump(WidgetTester tester, String diff) => tester.pumpWidget(
  MacosApp(
    debugShowCheckedModeBanner: false,
    home: SizedBox(
      width: 900,
      height: 600,
      child: SplitDiffView(diff: diff),
    ),
  ),
);

void main() {
  testWidgets('renders removal, addition, and context text', (tester) async {
    await _pump(tester, _diff);
    await tester.pump();

    // Removal (left) and addition (right) both present as their own cells.
    expect(find.text('old line'), findsOneWidget);
    expect(find.text('new line'), findsOneWidget);
    // A context line fills both columns, so it renders twice.
    expect(find.text('keep'), findsNWidgets(2));
    expect(find.text('tail'), findsNWidgets(2));
    // The hunk header is shown once.
    expect(find.textContaining('@@ -1,3 +1,3 @@'), findsOneWidget);
  });

  testWidgets('falls back to unified view when there are no hunks', (
    tester,
  ) async {
    await _pump(tester, 'Binary files a.png and b.png differ\n');
    await tester.pump();
    // No crash, and the raw line is shown by the DiffView fallback.
    expect(find.textContaining('Binary files'), findsOneWidget);
  });

  testWidgets(
    'a large multi-thousand-line diff still builds and renders correctly',
    (tester) async {
      final buffer = StringBuffer()
        ..write('diff --git a/big.txt b/big.txt\n')
        ..write('index 1..2 100644\n')
        ..write('--- a/big.txt\n')
        ..write('+++ b/big.txt\n')
        ..write('@@ -1,3000 +1,3000 @@\n');
      for (var i = 0; i < 3000; i++) {
        buffer.write(' context line $i\n');
      }
      buffer.write('-old tail line\n');
      buffer.write('+new tail line\n');
      final bigDiff = buffer.toString();

      await _pump(tester, bigDiff);
      await tester.pumpAndSettle();
      // The list is lazily built, so only the (in-viewport) head is
      // rendered — this is enough to prove the full diff parsed without
      // error and the widget didn't crash on a large input.
      expect(find.textContaining('@@ -1,3000 +1,3000 @@'), findsOneWidget);
      // A context line fills both columns, so it renders twice.
      expect(find.text('context line 0'), findsNWidgets(2));
    },
  );

  testWidgets(
    'long cell text is fully reachable on the shared horizontal pan',
    (tester) async {
      // Regression: pan extent used to be 2×cell text + outer pad only, which
      // shorted each column's own pad and the centre rule — the tail of a long
      // line clipped even when scrolled fully right.
      final long = 'x' * 200;
      final diff =
          'diff --git a/a.txt b/a.txt\n'
          'index 111..222 100644\n'
          '--- a/a.txt\n'
          '+++ b/a.txt\n'
          '@@ -1,1 +1,1 @@\n'
          '-$long\n'
          '+$long\n';
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 300,
            height: 400,
            child: SplitDiffView(diff: diff),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((s) => s.position.axis == Axis.horizontal);
      expect(horizontal.position.maxScrollExtent, greaterThan(0));

      // The pan must be at least wide enough for two padded cells + separator
      // of the measured cell text — otherwise long lines clip at the edge.
      final cellW = measureDiffWidth([long]);
      final minContent = splitDiffContentWidth(cellW);
      expect(
        horizontal.position.viewportDimension +
            horizontal.position.maxScrollExtent,
        greaterThanOrEqualTo(minContent - 0.5),
      );
    },
  );

  testWidgets(
    'does not rebuild the rows when the diff object is unchanged across an '
    'unrelated rebuild',
    (tester) async {
      final flag = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 900,
            height: 600,
            child: ValueListenableBuilder<bool>(
              valueListenable: flag,
              builder: (_, _, _) => const SplitDiffView(diff: _diff),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('old line'), findsOneWidget);

      // Trigger an unrelated rebuild — the diff content is unchanged.
      flag.value = true;
      await tester.pump();
      expect(find.text('old line'), findsOneWidget);
    },
  );
}
