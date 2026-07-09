// diffLineColor: per-line syntax color for a flat (unparsed) unified diff.
// Regression coverage for the consolidation onto diffLineKind for the
// add/remove/context overlap — this pins the actual colors so that
// consolidation is provably behavior-preserving, and covers the header/hunk-
// header cases that diffLineKind intentionally doesn't classify.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/diff_view.dart';

const _default = Color(0xFF123456);

void main() {
  group('diffLineColor', () {
    test('hunk headers are teal', () {
      expect(diffLineColor('@@ -1,3 +1,3 @@', _default), MacosColors.systemTealColor);
    });

    test('file-header lines are gray', () {
      for (final line in [
        'diff --git a/x b/x',
        'index 111..222 100644',
        '+++ b/x',
        '--- a/x',
        'new file mode 100644',
        'deleted file mode 100644',
        'rename from old.dart',
        'similarity index 90%',
      ]) {
        expect(
          diffLineColor(line, _default),
          MacosColors.systemGrayColor,
          reason: '"$line" should be a gray header line',
        );
      }
    });

    test('additions are green, removals are red', () {
      expect(diffLineColor('+added', _default), MacosColors.systemGreenColor);
      expect(diffLineColor('-removed', _default), MacosColors.systemRedColor);
    });

    test('context, no-newline marker, and blank lines use the default color', () {
      expect(diffLineColor(' context', _default), _default);
      expect(diffLineColor(r'\ No newline at end of file', _default), _default);
      expect(diffLineColor('', _default), _default);
    });
  });

  group('DiffView widget', () {
    testWidgets('lays out lines at a fixed itemExtent for O(1) scroll', (
      tester,
    ) async {
      const diff = '@@ -1,2 +1,2 @@\n-old line\n+new line\n context';
      await tester.pumpWidget(
        const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 400,
            height: 300,
            child: DiffView(diff: diff),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The uniform extent equals a single mono line's intrinsic height, so
      // it's a pure scroll-perf win with no layout change.
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.itemExtent, kDiffLineExtent);
      expect(find.text('+new line'), findsOneWidget);
    });

    testWidgets('a multi-line drag selection copies across lines', (
      tester,
    ) async {
      // The whole point of the single SelectionArea over plain Text rows:
      // per-line SelectableText could never carry a selection across lines.
      const diff = '@@ -1,2 +1,2 @@\n-old line\n+new line\n context';
      await tester.pumpWidget(
        const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(width: 400, height: 300, child: DiffView(diff: diff)),
        ),
      );
      await tester.pumpAndSettle();

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object?, Object?>)['text']
                as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      // Drag from the start of the first line to past the end of the last.
      final from = tester.getTopLeft(find.text('@@ -1,2 +1,2 @@'));
      final to =
          tester.getBottomRight(find.text(' context')) + const Offset(10, 0);
      final gesture = await tester.startGesture(
        from + const Offset(1, 1),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(copied, isNotNull, reason: 'copy reached the clipboard');
      for (final line in ['@@ -1,2 +1,2 @@', '-old line', '+new line']) {
        expect(copied, contains(line));
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });
}
