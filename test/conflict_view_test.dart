// ConflictView: colors <<<<<<</=======/>>>>>>> conflict regions, additionally
// recognizes the diff3/zdiff3 ||||||| ancestor marker (additive — two-way
// conflicts must render exactly as before), and detects binary content that
// arrived already (mis-)decoded from the SSH layer so it can show a
// placeholder instead of a wall of replacement-character garbage.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/features/repository/conflict_view.dart';

const _twoWayConflict =
    'before\n'
    '<<<<<<< HEAD\n'
    'our line\n'
    '=======\n'
    'their line\n'
    '>>>>>>> branch\n'
    'after\n';

const _diff3Conflict =
    'before\n'
    '<<<<<<< HEAD\n'
    'our line\n'
    '||||||| base\n'
    'ancestor line\n'
    '=======\n'
    'their line\n'
    '>>>>>>> branch\n'
    'after\n';

Future<void> _pump(WidgetTester tester, String content) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: MacosWindow(
        child: ContentArea(builder: (_, _) => ConflictView(content: content)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color? _backgroundOf(WidgetTester tester, String text) {
  // Bands live on the row Container (full-width soft fill under DiffPan),
  // not on Text.style.backgroundColor — same pattern as the other diff
  // surfaces after the layout polish.
  final textFinder = find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == text,
  );
  final container = tester.widget<Container>(
    find.ancestor(of: textFinder, matching: find.byType(Container)).first,
  );
  return container.color;
}

void main() {
  group('two-way conflicts (no diff3 marker)', () {
    testWidgets('renders ours/separator/theirs with the original coloring', (
      tester,
    ) async {
      await _pump(tester, _twoWayConflict);

      expect(find.text('our line'), findsOneWidget);
      expect(find.text('their line'), findsOneWidget);
      expect(
        _backgroundOf(tester, 'our line'),
        MacosColors.systemBlueColor.withValues(alpha: 0.10),
      );
      expect(
        _backgroundOf(tester, 'their line'),
        MacosColors.systemGreenColor.withValues(alpha: 0.10),
      );
      expect(
        _backgroundOf(tester, '<<<<<<< HEAD'),
        MacosColors.systemBlueColor.withValues(alpha: 0.18),
      );
      expect(
        _backgroundOf(tester, '>>>>>>> branch'),
        MacosColors.systemGreenColor.withValues(alpha: 0.18),
      );
      // No ancestor marker present, so nothing should be styled as one.
      expect(find.text('||||||| base'), findsNothing);
    });
  });

  group('diff3/zdiff3 ancestor marker', () {
    testWidgets('ancestor section gets its own distinct color, not ours', (
      tester,
    ) async {
      await _pump(tester, _diff3Conflict);

      expect(find.text('ancestor line'), findsOneWidget);

      final oursBg = _backgroundOf(tester, 'our line');
      final ancestorBg = _backgroundOf(tester, 'ancestor line');
      final theirsBg = _backgroundOf(tester, 'their line');

      expect(oursBg, MacosColors.systemBlueColor.withValues(alpha: 0.10));
      expect(ancestorBg, MacosColors.systemOrangeColor.withValues(alpha: 0.10));
      expect(theirsBg, MacosColors.systemGreenColor.withValues(alpha: 0.10));
      // The three regions must be visually distinguishable from each other.
      expect(ancestorBg, isNot(oursBg));
      expect(ancestorBg, isNot(theirsBg));

      expect(
        _backgroundOf(tester, '||||||| base'),
        MacosColors.systemOrangeColor.withValues(alpha: 0.18),
      );
    });

    testWidgets('theirs still starts correctly after an ancestor section', (
      tester,
    ) async {
      await _pump(tester, _diff3Conflict);

      expect(
        _backgroundOf(tester, 'their line'),
        MacosColors.systemGreenColor.withValues(alpha: 0.10),
      );
      expect(
        _backgroundOf(tester, '>>>>>>> branch'),
        MacosColors.systemGreenColor.withValues(alpha: 0.18),
      );
    });
  });

  group('binary content detection', () {
    testWidgets('a NUL byte trips the binary placeholder', (tester) async {
      await _pump(tester, 'abc${String.fromCharCode(0)}def');

      expect(
        find.textContaining('Binary conflict — text preview unavailable'),
        findsOneWidget,
      );
      // The raw (garbled) content must not be rendered as conflict lines.
      expect(find.textContaining('abc'), findsNothing);
    });

    testWidgets(
      'a high density of replacement characters trips the binary placeholder',
      (tester) async {
        // Mimics what upstream UTF-8 decode-with-allowMalformed produces for
        // genuinely binary content: mostly U+FFFD noise.
        final garbage = '�' * 200;
        await _pump(tester, garbage);

        expect(
          find.textContaining('Binary conflict — text preview unavailable'),
          findsOneWidget,
        );
      },
    );

    testWidgets('an ordinary two-way conflict is not misdetected as binary', (
      tester,
    ) async {
      await _pump(tester, _twoWayConflict);

      expect(
        find.textContaining('Binary conflict — text preview unavailable'),
        findsNothing,
      );
      expect(find.text('our line'), findsOneWidget);
    });
  });
}
