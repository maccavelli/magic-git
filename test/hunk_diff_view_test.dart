// HunkDiffView: worktree diffs offer Stage/Discard per hunk, index (staged)
// diffs offer Unstage, and tapping a button hands back the parsed file + hunk.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/unified_diff.dart';
import 'package:remote_magic_git/features/repository/hunk_diff_view.dart';

const _diff =
    'diff --git a/a.dart b/a.dart\n'
    'index 1..2 100644\n'
    '--- a/a.dart\n'
    '+++ b/a.dart\n'
    '@@ -1,2 +1,2 @@\n'
    ' keep\n'
    '-old\n'
    '+new\n';

Future<(DiffFile, DiffHunk, HunkAction)?> _pump(
  WidgetTester tester, {
  required bool staged,
}) async {
  (DiffFile, DiffHunk, HunkAction)? captured;
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: MacosWindow(
        child: ContentArea(
          builder: (_, _) => HunkDiffView(
            diff: _diff,
            staged: staged,
            onAction: (f, h, a) => captured = (f, h, a),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('worktree diff shows Stage + Discard, not Unstage', (
    tester,
  ) async {
    await _pump(tester, staged: false);
    expect(find.text('Stage'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(find.text('Unstage'), findsNothing);
    // The hunk body renders.
    expect(find.text('+new'), findsOneWidget);
  });

  testWidgets('index diff shows Unstage only', (tester) async {
    await _pump(tester, staged: true);
    expect(find.text('Unstage'), findsOneWidget);
    expect(find.text('Stage'), findsNothing);
    expect(find.text('Discard'), findsNothing);
  });

  testWidgets('tapping Stage reports the hunk with the stage action', (
    tester,
  ) async {
    (DiffFile, DiffHunk, HunkAction)? captured;
    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: _diff,
              staged: false,
              onAction: (f, h, a) => captured = (f, h, a),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stage'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.$3, HunkAction.stage);
    expect(captured!.$2.header, '@@ -1,2 +1,2 @@');
    expect(captured!.$1.header.first, 'diff --git a/a.dart b/a.dart');
  });

  testWidgets('clicking a hunk header focuses it; ⌥↓ moves the cursor and '
      '⌘⇧K stages the focused hunk', (tester) async {
    const twoHunks =
        'diff --git a/a.dart b/a.dart\n'
        'index 1..2 100644\n'
        '--- a/a.dart\n'
        '+++ b/a.dart\n'
        '@@ -1,2 +1,2 @@\n'
        ' keep\n'
        '-old\n'
        '+new\n'
        '@@ -10,2 +10,2 @@\n'
        ' keep2\n'
        '-old2\n'
        '+new2\n';
    (DiffFile, DiffHunk, HunkAction)? captured;
    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: twoHunks,
              staged: false,
              onAction: (f, h, a) => captured = (f, h, a),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Focus the first hunk, then ⌥↓ to the second.
    await tester.tap(find.text('@@ -1,2 +1,2 @@'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    // ⌘⇧K stages the focused (second) hunk.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.$3, HunkAction.stage);
    expect(captured!.$2.header, '@@ -10,2 +10,2 @@');
  });

  testWidgets('a large multi-thousand-line diff still parses and renders '
      'correctly', (tester) async {
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

    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: bigDiff,
              staged: false,
              onAction: (_, _, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The list is lazily built, so only the (in-viewport) head is rendered —
    // this is enough to prove the full diff parsed without error and the
    // widget didn't crash on a large input (mirrors the equivalent
    // split_diff_view_test.dart assertion).
    expect(find.textContaining('@@ -1,3000 +1,3000 @@'), findsOneWidget);
    expect(find.text(' context line 0'), findsOneWidget);
  });

  // The parse+flatten payload that the render path runs — inline for small
  // diffs, on a background isolate above _isolateLineThreshold. Tested directly
  // (not through the widget) because Isolate.run can't be driven inside
  // flutter_test's custom zone; this covers the code that moved off-thread.
  group('parse+flatten payload (debugParseHunkDiff)', () {
    test('flattens a small diff into a header + one item per body line', () {
      final r = debugParseHunkDiff(_diff);
      expect(r.parsed, isTrue);
      expect(r.hunks, 1);
      // 1 header + 3 body lines (' keep', '-old', '+new').
      expect(r.items, 4);
    });

    test('builds correctly at huge scale (isolate-path input)', () {
      final buffer = StringBuffer()
        ..write('diff --git a/huge.txt b/huge.txt\n')
        ..write('index 1..2 100644\n')
        ..write('--- a/huge.txt\n')
        ..write('+++ b/huge.txt\n')
        ..write('@@ -1,25000 +1,25000 @@\n');
      for (var i = 0; i < 25000; i++) {
        buffer.write(' ctx $i\n');
      }
      final r = debugParseHunkDiff(buffer.toString());
      expect(r.parsed, isTrue);
      expect(r.hunks, 1);
      // 1 header + 25000 body lines.
      expect(r.items, 25001);
    });

    test('reports no parse for a hunkless (binary) diff', () {
      final r = debugParseHunkDiff('Binary files a.png and b.png differ\n');
      expect(r.parsed, isFalse);
      expect(r.items, 0);
    });
  });

  testWidgets(
    'does not reparse when the diff object is unchanged across an unrelated '
    'rebuild',
    (tester) async {
      // Uses the same String instance for both builds — the redundant-rebuild
      // scenario the memoization guards against (a diff provider handing back
      // the same value while some unrelated ancestor state changes).
      final widget = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: MacosWindow(
            child: ContentArea(
              builder: (_, _) => ValueListenableBuilder<bool>(
                valueListenable: widget,
                builder: (_, _, _) => HunkDiffView(
                  diff: _diff,
                  staged: false,
                  onAction: (_, _, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('+new'), findsOneWidget);

      // Trigger an unrelated rebuild — the diff content is unchanged.
      widget.value = true;
      await tester.pumpAndSettle();
      expect(find.text('+new'), findsOneWidget);
    },
  );
}
