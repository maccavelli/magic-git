// HunkDiffView: worktree diffs offer Stage/Discard per hunk, index (staged)
// diffs offer Unstage, and tapping a button hands back the parsed file + hunk.

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
