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
  group('layout constants', () {
    test('split pan width accounts for both cell pads and the separator', () {
      // Two columns of (text + pad*2) plus the centre rule — never merely
      // 2× the cell text (that shorted the pan and clipped long lines).
      const cell = 100.0;
      final content = splitDiffContentWidth(cell);
      expect(content, 2 * (cell + kDiffHPad * 2) + kDiffSplitSeparator);
      // DiffPan adds kDiffHPad*2 on top of maxLineWidth; the helper inverts
      // that so the final extent equals splitDiffContentWidth.
      expect(
        splitDiffPanMaxLineWidth(cell) + kDiffHPad * 2,
        content,
      );
    });

    test('strut height matches the fixed itemExtent', () {
      // The force-strut is what keeps glyph runs inside the itemExtent slot
      // under SelectionArea; if these drift, text clips ("out of margins").
      expect(kDiffStrut.fontSize, 12);
      expect(kDiffStrut.height, 1.35);
      expect(kDiffStrut.forceStrutHeight, isTrue);
      expect(kDiffLineExtent, 12 * 1.35);
    });
  });

  group('diffLineBackground', () {
    test('additions and removals get soft fills; headers stay clear', () {
      expect(diffLineBackground('+added'), isNotNull);
      expect(diffLineBackground('-removed'), isNotNull);
      expect(diffLineBackground(' context'), isNull);
      expect(diffLineBackground('@@ -1 +1 @@'), isNull);
      expect(diffLineBackground('diff --git a/x b/x'), isNull);
    });
  });

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

      // One shared horizontal scroll for the whole diff — not the old
      // per-line independent scrollers — so all lines pan to their ends
      // together beneath a single bottom scrollbar.
      final horizontal = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .where((s) => s.scrollDirection == Axis.horizontal);
      expect(horizontal, hasLength(1));
    });

    testWidgets('no-wrap makes long lines horizontally scrollable to their end', (
      tester,
    ) async {
      final diff = '@@ -1,1 +1,1 @@\n+${'x' * 400}\n';
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Center(
            child: SizedBox(
              width: 200,
              height: 300,
              child: DiffView(diff: diff),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((s) => s.position.axis == Axis.horizontal);
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('a horizontal wheel pans the whole diff at once', (
      tester,
    ) async {
      final diff = '@@ -1,1 +1,1 @@\n+${'x' * 400}\n';
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Center(
            child: SizedBox(
              width: 200,
              height: 300,
              child: DiffView(diff: diff),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((s) => s.position.axis == Axis.horizontal);
      expect(horizontal.position.pixels, 0);

      final center = tester.getCenter(find.byType(DiffView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(150, 0)));
      await tester.pump();
      expect(horizontal.position.pixels, greaterThan(0));
    });

    testWidgets('a horizontal trackpad swipe pans the whole diff at once', (
      tester,
    ) async {
      final diff = '@@ -1,1 +1,1 @@\n+${'x' * 400}\n';
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Center(
            child: SizedBox(
              width: 200,
              height: 300,
              child: DiffView(diff: diff),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((s) => s.position.axis == Axis.horizontal);

      final center = tester.getCenter(find.byType(DiffView));
      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pointer.panZoomStart(center));
      await tester.pump();
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(center, pan: const Offset(-150, 0)),
      );
      await tester.pump();
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pump();
      expect(horizontal.position.pixels.abs(), greaterThan(0));
    });

    testWidgets('wrap mode drops the fixed extent and the horizontal scroll', (
      tester,
    ) async {
      const diff = '@@ -1,2 +1,2 @@\n-old line\n+new line\n context';
      await tester.pumpWidget(
        const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 400,
            height: 300,
            child: DiffView(diff: diff, wrap: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Wrapped rows have variable height, so the fixed extent is dropped and
      // nothing scrolls horizontally.
      expect(tester.widget<ListView>(find.byType(ListView)).itemExtent, isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
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
