// The things every diff renderer must now agree on.
//
// Four widgets render diffs — DiffView, HunkDiffView, SplitDiffView and
// CommitPatchView — and they had drifted into disagreeing about behaviour a user
// reads as one feature. These pin the agreements, so the next renderer (or the
// next edit to an existing one) can't quietly re-fork them.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/unified_diff.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/commit_patch_view.dart';
import 'package:remote_magic_git/features/common/diff_view.dart';
import 'package:remote_magic_git/features/common/split_diff_view.dart';
import 'package:remote_magic_git/features/repository/hunk_diff_view.dart';

const _repo = '/repo';
const _hash = 'abc1234';

const _diff =
    'diff --git a/f.dart b/f.dart\n'
    'index 111..222 100644\n'
    '--- a/f.dart\n'
    '+++ b/f.dart\n'
    '@@ -1,4 +1,4 @@\n'
    ' keep\n'
    '-old line that runs on and on and on and on and on and on and on and on\n'
    '+new line that runs on and on and on and on and on and on and on and on\n'
    ' tail\n';

/// A binary change: real diff text, no hunks at all. Every renderer has to fall
/// back to showing it rather than parsing it into rows.
const _binaryDiff =
    'diff --git a/logo.png b/logo.png\n'
    'index 111..222 100644\n'
    'Binary files a/logo.png and b/logo.png differ\n';

/// Horizontal scroll views actually in the tree.
Finder _horizontalScrolls() => find.byWidgetPredicate(
  (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(width: 400, height: 300, child: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('one horizontal pan for the whole diff, not one per line', () {
    // Every line used to carry its own SingleChildScrollView, so scrolling
    // sideways moved that one line and left the rest behind — the diff came
    // apart under the cursor, and there was no way to read the ends of a run of
    // long lines together. Now the whole diff pans as a unit, in every renderer.

    testWidgets('HunkDiffView', (tester) async {
      await _pump(
        tester,
        HunkDiffView(diff: _diff, staged: false, onAction: (_, _, _) {}),
      );
      expect(_horizontalScrolls(), findsOneWidget);
    });

    testWidgets('SplitDiffView', (tester) async {
      await _pump(tester, const SplitDiffView(diff: _diff));
      expect(_horizontalScrolls(), findsOneWidget);
    });

    testWidgets('DiffView', (tester) async {
      await _pump(tester, const DiffView(diff: _diff));
      expect(_horizontalScrolls(), findsOneWidget);
    });
  });

  testWidgets("a hunk's actions stay reachable however far the diff is panned", (
    tester,
  ) async {
    // The header carries Stage and Discard. If it panned with the content, then
    // panning right to read the end of a long line would carry the buttons off
    // the screen with it — the diff's own actions gone exactly when the diff is
    // at its widest. Controls pin; text pans.
    await _pump(
      tester,
      HunkDiffView(diff: _diff, staged: false, onAction: (_, _, _) {}),
    );
    expect(find.text('Stage'), findsOneWidget);

    // A context line: this is diff *text*, so it must pan.
    final line = find.text(' keep');
    final stageBefore = tester.getRect(find.text('Stage'));
    final lineBefore = tester.getRect(line);

    final pan = tester.widget<SingleChildScrollView>(_horizontalScrolls());
    final extent = pan.controller!.position.maxScrollExtent;
    expect(extent, greaterThan(0), reason: 'sanity: there is somewhere to pan');
    pan.controller!.jumpTo(extent);
    await tester.pumpAndSettle();

    expect(
      tester.getRect(line).left,
      closeTo(lineBefore.left - extent, 0.5),
      reason: 'the diff text pans, by exactly the pan',
    );
    expect(
      tester.getRect(find.text('Stage')),
      stageBefore,
      reason: 'but the hunk actions hold still — they are controls, and they '
          'have to stay reachable at any pan, not slide off the right edge '
          'exactly when the diff is at its widest',
    );
  });

  testWidgets('green means the same thing in the unified and split views', (
    tester,
  ) async {
    // The split view strips the leading marker, so it cannot ask
    // `diffLineColor` what an addition looks like — which is how it ended up
    // owning a second, independent copy of the palette. Both now route through
    // diffKindColor, so this is true by construction rather than by luck.
    await _pump(tester, const SplitDiffView(diff: _diff));

    final added = tester.widget<Text>(
      find.text('new line that runs on and on and on and on and on and on and '
          'on and on'),
    );
    expect(
      added.style!.color,
      diffKindColor(DiffLineKind.add, const Color(0xFF000000)),
    );
  });

  group('a diff with no hunks still renders', () {
    // A binary change parses to nothing. "Nothing" is a RESULT, not an absence —
    // conflating the two (a parse that returned null vs. a parse that hadn't
    // finished) made a binary file render as a spinner that never cleared.

    testWidgets('SplitDiffView falls back and shows it', (tester) async {
      await _pump(tester, const SplitDiffView(diff: _binaryDiff));
      expect(find.byType(ProgressCircle), findsNothing);
      expect(find.textContaining('Binary files'), findsOneWidget);
    });

    testWidgets('HunkDiffView falls back and shows it', (tester) async {
      await _pump(
        tester,
        HunkDiffView(diff: _binaryDiff, staged: false, onAction: (_, _, _) {}),
      );
      expect(find.byType(ProgressCircle), findsNothing);
      expect(find.textContaining('Binary files'), findsOneWidget);
    });
  });

  testWidgets('an expander whose blob cannot be read says so, instead of '
      'sitting there doing nothing', (tester) async {
    // The gap control used to go quietly inert on a failed blob read: it stayed
    // on screen, kept its pointer cursor, and did nothing at all when clicked —
    // forever, with no explanation anywhere.
    final container = ProviderContainer(
      // Riverpod 3 retries a failed provider on a backoff timer; this test is
      // about what the pane shows for a failure, not about the retry.
      retry: (_, _) => null,
      overrides: [
        gitServiceProvider.overrideWithValue(_FailingBlobGit()),
        blobLinesProvider((
          _repo,
          _hash,
          'f.dart',
        )).overrideWith((ref) async => throw Exception('object not found')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 600,
            height: 400,
            child: CommitPatchView(repoPath: _repo, hash: _hash, diff: _patch),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The gap is there and offers to open.
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.chevron_down,
      ),
      findsWidgets,
    );

    await tester.tap(find.textContaining('Show ').first);
    await tester.pumpAndSettle();

    expect(
      find.textContaining("couldn't be read"),
      findsWidgets,
      reason: 'a control that cannot act must say why, not fail silently',
    );
  });
}

/// f.dart as of the commit — except the read fails.
class _FailingBlobGit extends GitService {
  _FailingBlobGit() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<String> showBlob(String repoPath, String rev, String path) async =>
      throw Exception('object not found');
}

/// A commit that changed line 20 of a 40-line file, so git's -U3 leaves gaps
/// above and below — hence expanders.
const _patch =
    'commit abc1234\n'
    'Author: Dev <d@e>\n'
    '\n'
    '    tweak line 20\n'
    '\n'
    'diff --git a/f.dart b/f.dart\n'
    'index 111..222 100644\n'
    '--- a/f.dart\n'
    '+++ b/f.dart\n'
    '@@ -17,7 +17,7 @@\n'
    ' line 17\n'
    ' line 18\n'
    ' line 19\n'
    '-line 20\n'
    '+line 20 changed\n'
    ' line 21\n'
    ' line 22\n'
    ' line 23\n';
