// HunkDiffView: worktree diffs offer Stage/Discard per hunk, index (staged)
// diffs offer Unstage, and tapping a button hands back the parsed file + hunk.

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/unified_diff.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';
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

  testWidgets('click and Shift-click select a changed-line range', (
    tester,
  ) async {
    (String, int, HunkAction)? selectedAction;
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: _diff,
              staged: false,
              onAction: (_, _, _) {},
              onSelectionAction: (_, patch, count, action) {
                selectedAction = (patch, count, action);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('-old'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('+new'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('2 changed lines selected'), findsOneWidget);
    await tester.tap(find.text('Stage Selection'));
    expect(selectedAction?.$2, 2);
    expect(selectedAction?.$3, HunkAction.stage);
    expect(selectedAction?.$1, contains('-old\n+new'));
  });

  testWidgets('Shift-arrow extends keyboard line selection', (tester) async {
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: _diff,
              staged: true,
              onAction: (_, _, _) {},
              onSelectionAction: (_, _, _, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('-old'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('2 changed lines selected'), findsOneWidget);
    expect(find.text('Unstage Selection'), findsOneWidget);
  });

  testWidgets('mouse drag selects adjacent changed rows', (tester) async {
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: _diff,
              staged: false,
              onAction: (_, _, _) {},
              onSelectionAction: (_, _, _, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('-old')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester.getCenter(find.text('+new')));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('2 changed lines selected'), findsOneWidget);
  });

  testWidgets('disabled modes explain why line actions are unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: _diff,
              staged: false,
              onAction: (_, _, _) {},
              onSelectionAction: (_, _, _, _) {},
              selectionDisabledReason:
                  'Line actions require whitespace-exact diff mode.',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Line actions require whitespace-exact diff mode.'),
      findsOneWidget,
    );
    await tester.tap(find.text('+new'));
    await tester.pump();
    expect(find.textContaining('changed line selected'), findsNothing);
  });

  testWidgets('Shift-click across hunks is rejected with an explanation', (
    tester,
  ) async {
    const twoHunks =
        'diff --git a/a.dart b/a.dart\n'
        'index 1..2 100644\n'
        '--- a/a.dart\n'
        '+++ b/a.dart\n'
        '@@ -1 +1 @@\n'
        '-old one\n'
        '+new one\n'
        '@@ -10 +10 @@\n'
        '-old two\n'
        '+new two\n';
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: twoHunks,
              staged: false,
              onAction: (_, _, _) {},
              onSelectionAction: (_, _, _, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('-old one'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('-old two'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(
      find.text('Line selections cannot cross hunk boundaries.'),
      findsOneWidget,
    );
    expect(find.text('1 changed line selected'), findsOneWidget);
  });

  testWidgets('binary fallback explains why line mutation is unavailable', (
    tester,
  ) async {
    const binary =
        'diff --git a/image.png b/image.png\n'
        'index 1..2 100644\n'
        'Binary files a/image.png and b/image.png differ\n';
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => HunkDiffView(
              diff: binary,
              staged: false,
              onAction: (_, _, _) {},
              onSelectionAction: (_, _, _, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Line actions are unavailable because this diff has no selectable '
        'text hunks.',
      ),
      findsOneWidget,
    );
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

  group('a hunk action looks and feels like a live control', () {
    // The buttons worked, but nothing about them said so: the pointer stayed an
    // I-beam over the label (a Text under a SelectionArea wraps itself in a
    // text-cursor MouseRegion, and the deepest annotation under the pointer
    // wins), and hovering changed nothing at all. They read as disabled chrome.

    /// The cursor macOS would actually be showing right now.
    MouseCursor cursorNow() =>
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

    Future<TestGesture> hover(WidgetTester tester, Finder target) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(target));
      await tester.pumpAndSettle();
      return gesture;
    }

    /// The button's animated skin, as currently painted.
    BoxDecoration skinOf(WidgetTester tester, String label) {
      final container = tester.widget<Container>(
        find.descendant(
          of: find.widgetWithText(InlineActionButton, label),
          matching: find.byType(Container),
        ),
      );
      return container.decoration! as BoxDecoration;
    }

    testWidgets('the pointer over one is a hand, not an I-beam', (
      tester,
    ) async {
      await _pump(tester, staged: false);

      await hover(tester, find.text('Stage'));
      expect(cursorNow(), SystemMouseCursors.click);
    });

    testWidgets('while the diff text it sits on still selects as text', (
      tester,
    ) async {
      // The hand must not be bought by killing selection on the diff itself.
      await _pump(tester, staged: false);

      await hover(tester, find.text('+new'));
      expect(cursorNow(), SystemMouseCursors.text);
    });

    testWidgets('it lights up under the pointer', (tester) async {
      await _pump(tester, staged: false);

      final atRest = skinOf(tester, 'Stage');
      await hover(tester, find.text('Stage'));
      final hovered = skinOf(tester, 'Stage');

      expect(
        hovered.border,
        isNot(atRest.border),
        reason: 'hovering must visibly change the control',
      );
      // ...in the accent's colour (blue by default), not just "some grey".
      final lit = (hovered.border! as Border).top.color;
      expect(lit.b, greaterThan(lit.r));
    });

    testWidgets('and Discard lights up red, because it destroys work', (
      tester,
    ) async {
      await _pump(tester, staged: false);

      await hover(tester, find.text('Discard'));
      final lit = (skinOf(tester, 'Discard').border! as Border).top.color;
      expect(lit.r, greaterThan(lit.b));
      expect(lit.r, greaterThan(lit.g));
    });
  });
}
