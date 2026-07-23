// The History panel's per-commit actions menu: it appears once a commit is
// selected, and "Amend last commit" is offered only for HEAD (the first log
// row). Also the multi-selection machinery (⌘/⇧-click, compare-two pane,
// right-click menu, bulk cherry-pick/revert). Uses a fake GitService so no
// SSH is touched.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/create_tag_sheet.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/commit_patch_view.dart';
import 'package:remote_magic_git/features/common/sheet_chrome.dart';
import 'package:remote_magic_git/features/history/commit_graph_view.dart'
    show kGraphRowHeight;
import 'package:remote_magic_git/features/history/history_minimap.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeGit extends GitService {
  _FakeGit(this.commits) : super(SSHCommandExecutor(SSHClientManager()));
  final List<GitCommit> commits;

  final List<String> cherryPicked = [];
  final List<String> reverted = [];

  /// Cherry-pick/revert of this hash throws a [GitException] — a stand-in
  /// for a conflict, which is how GitService signals one.
  String? conflictOn;

  /// The named arguments of the most recent [log] call — what the filter UI
  /// actually asked git for.
  Map<String, Object?>? lastLogArgs;

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
  }) async {
    lastLogArgs = {
      'grep': grep,
      'author': author,
      'since': since,
      'until': until,
      // The panel's file field is a search term, not a literal path — it must
      // arrive as `pathQuery` (compiled to fuzzy, case-insensitive pathspecs),
      // never as `path` (an exact pathspec, which is file history's language).
      'pathQuery': pathQuery,
      'sha': sha,
      'all': all,
      'noMerges': noMerges,
    };
    return commits;
  }

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async =>
      'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';

  @override
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async => 'diff --git a/r b/r\n@@ -1 +1 @@\n-old\n+$range';

  SSHCommandResult _mutate(List<String> record, String hash) {
    if (hash == conflictOn) {
      throw const GitException(
        'conflict',
        SSHCommandResult(exitCode: 1, stdout: '', stderr: 'CONFLICT'),
      );
    }
    record.add(hash);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> cherryPick(
    String repoPath,
    String hash, {
    int? mainline,
  }) async => _mutate(cherryPicked, hash);

  @override
  Future<SSHCommandResult> revert(
    String repoPath,
    String hash, {
    int? mainline,
  }) async => _mutate(reverted, hash);
}

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

const _repo = '/srv/repo';

Future<void> _pump(
  WidgetTester tester,
  List<GitCommit> commits, {
  _FakeGit? git,
  // For tests that open the Create Tag sheet, which watches the remotes
  // and remote-tags providers — unoverridden they'd error against the fake
  // executor and leave Riverpod retry timers pending.
  bool tagSheetProviders = false,
}) async {
  // The zoom setter persists through SharedPreferences — back it with the
  // in-memory mock so writes don't hit a missing platform channel.
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git ?? _FakeGit(commits)),
      repoWatchProvider.overrideWith((ref, repoPath) => const Stream.empty()),
      if (tagSheetProviders) ...[
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
      ],
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: HistoryView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _actionsMenu => find.byWidgetPredicate(
  (w) => w is MacosIcon && w.icon == CupertinoIcons.line_horizontal_3,
);

void main() {
  final head = _c('aaaaaaa1111111', 'head commit');
  final older = _c('bbbbbbb2222222', 'old commit');

  testWidgets('the commit-list divider drags and persists its width', (
    tester,
  ) async {
    await _pump(tester, [head]);
    // The divider sits at the master pane's right edge (default 420).
    final gesture = await tester.startGesture(
      const Offset(420.5, 300),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(15, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_historyList'), 435);
  });

  testWidgets('no actions menu until a commit is selected', (tester) async {
    await _pump(tester, [head, older]);
    expect(find.text('Select a commit'), findsOneWidget);
    expect(_actionsMenu, findsNothing);
  });

  testWidgets('the commit graph lays out rows at a fixed itemExtent', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    // Rows are all kGraphRowHeight, so the graph list pins that as its
    // itemExtent — the list can skip per-row layout for its scroll math.
    final extents = tester
        .widgetList<ListView>(find.byType(ListView))
        .map((l) => l.itemExtent);
    expect(extents, contains(kGraphRowHeight));
  });

  testWidgets('HEAD commit offers Amend when not filtering by all-branches', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    // Turn off all-branches filter so history is strictly `git log HEAD`.
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is MacosIcon && w.icon == CupertinoIcons.square_stack_3d_up_fill,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();

    expect(_actionsMenu, findsOneWidget);
    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();

    // Labels interpolate the target hash (Tower/Fork convention), so the
    // menu always says exactly which commit it acts on.
    expect(find.text('Checkout aaaaaaa'), findsOneWidget);
    expect(find.text('Cherry-pick aaaaaaa'), findsOneWidget);
    expect(find.text('Revert aaaaaaa'), findsOneWidget);
    expect(find.text('Amend last commit'), findsOneWidget);
  });

  testWidgets('non-HEAD commit hides Amend', (tester) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('old commit'));
    await tester.pumpAndSettle();

    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();

    expect(find.text('Revert bbbbbbb'), findsOneWidget);
    expect(find.text('Amend last commit'), findsNothing);
  });

  testWidgets('an active all-branches filter hides Amend on the top row', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    // Under all-branches (default true), the shown list isn't `git log HEAD`,
    // so its first row need not be the real HEAD — Amend (which rewrites the
    // actual HEAD) must not be offered.
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();

    expect(find.text('Revert aaaaaaa'), findsOneWidget);
    expect(find.text('Amend last commit'), findsNothing);
  });

  testWidgets('the text-prompt sheet is width-capped, not window-filling', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Branch from aaaaaaa…'));
    await tester.pumpAndSettle();

    // The prompt is open at the standard sheet width rather than ballooning
    // to fill the window — measured on the RENDERED sheet, not a declared
    // SizedBox (inner widths can be silently ignored; see SizedSheet).
    final sheet = find.byType(MacosSheet);
    expect(sheet, findsOneWidget);
    expect(tester.getSize(sheet).width, kSheetWidth);
  });

  // ── Multi-selection ──────────────────────────────────────────────────────

  final mid = _c('ccccccc3333333', 'mid commit');

  Future<void> metaClick(WidgetTester tester, Finder target) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(target);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  Future<void> shiftClick(WidgetTester tester, Finder target) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(target);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('⌘-click builds a two-commit selection and shows the compare '
      'pane', (tester) async {
    await _pump(tester, [head, mid, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await metaClick(tester, find.text('old commit'));

    // Two selected → the pane diffs older → newer.
    expect(find.text('Comparing bbbbbbb → aaaaaaa'), findsOneWidget);

    // ⌘-clicking a selected row deselects it, collapsing back to one.
    await metaClick(tester, find.text('old commit'));
    expect(find.text('Comparing bbbbbbb → aaaaaaa'), findsNothing);
    expect(find.text('aaaaaaa111'), findsOneWidget); // single-diff header
  });

  testWidgets('⇧-click selects the contiguous range from the anchor', (
    tester,
  ) async {
    await _pump(tester, [head, mid, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await shiftClick(tester, find.text('old commit'));

    expect(find.text('3 commits selected'), findsOneWidget);
    expect(find.textContaining('Right-click the selection'), findsOneWidget);
  });

  testWidgets('⌘-deselecting the anchor re-seats it on a still-selected row, '
      'so a later ⇧-click ranges from the right place', (tester) async {
    await _pump(tester, [head, mid, older]);
    // Build {head, older} with the anchor on `older` (the last ⌘-clicked row).
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await metaClick(tester, find.text('old commit'));
    // ⌘-click `older` again to deselect it — it was the anchor. The old code
    // left the anchor pointing at this just-removed row; a following ⇧-click
    // then ranged from a deselected commit (a bug that could mis-target the
    // bulk cherry-pick/revert). The fix re-seats the anchor on `head`.
    await metaClick(tester, find.text('old commit'));

    // ⇧-click back down to `older`: from the correct anchor (head) this is the
    // full contiguous range. From the stale anchor (older) it would collapse
    // to a single commit instead.
    await shiftClick(tester, find.text('old commit'));
    expect(find.text('3 commits selected'), findsOneWidget);
  });

  testWidgets('the diff header word-wrap toggle flips and activates', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();

    // The toggle lives in the diff header regardless of whether the patch
    // itself loaded, so a single selected commit is enough to exercise it.
    final toggle = find.byWidgetPredicate(
      (w) => w is MacosIcon && w.icon == CupertinoIcons.arrow_turn_down_left,
    );
    expect(toggle, findsOneWidget);
    expect(tester.widget<MacosIcon>(toggle).color, isNull);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // Now active — the persisted setting flipped, colouring the icon.
    expect(tester.widget<MacosIcon>(toggle).color, MacosColors.systemBlueColor);
  });

  testWidgets('the enlarged diff sheet honors the persisted wrap setting', (
    tester,
  ) async {
    // Regression: the sheet used to read the setting for its toggle button but
    // never pass it to its own DiffView, so toggling there only wrapped the
    // parent view. The sheet's DiffView must follow the setting itself.
    SharedPreferences.setMockInitialValues({'historyDiffWrap': true});
    final container = ProviderContainer(
      overrides: [
        commitDiffProvider.overrideWith((ref, arg) => '@@ -1,1 +1,1 @@\n+hi\n'),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: CommitDiffSheet(repoPath: _repo, hash: 'abcabc1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<CommitPatchView>(find.byType(CommitPatchView)).wrap,
      isTrue,
    );
  });

  testWidgets('a lost ⌘ key-up is recovered — app deactivation unfreezes the '
      'commit list scroll', (tester) async {
    await _pump(tester, [head, mid, older]);
    ListView list() =>
        tester.widgetList<ListView>(find.byType(ListView)).first;
    expect(list().physics, isNot(isA<NeverScrollableScrollPhysics>()));

    // ⌘ goes down (⌘-scroll zoom arms), freezing the list's own scrolling…
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(list().physics, isA<NeverScrollableScrollPhysics>());

    // …but its key-up is lost to another surface. Focus leaving the app drops
    // the held state rather than trusting the stale "still pressed", so the
    // list doesn't stay frozen.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(list().physics, isNot(isA<NeverScrollableScrollPhysics>()));

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  });

  testWidgets('⌘C copies every selected SHA, newest first', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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

    await _pump(tester, [head, mid, older]);
    await tester.tap(find.text('old commit'));
    await tester.pumpAndSettle();
    // ⌘-click ABOVE the anchor: on-screen order (newest first) must win over
    // click order in what lands on the clipboard.
    await metaClick(tester, find.text('head commit'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(copied.single, 'aaaaaaa1111111\nbbbbbbb2222222');
  });

  testWidgets('right-click outside the selection collapses to the clicked '
      'row', (tester) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.text('old commit'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    // The menu targets the clicked row, not the pre-click selection.
    expect(find.text('Checkout bbbbbbb'), findsOneWidget);
    expect(find.text('Cherry-pick bbbbbbb'), findsOneWidget);
    expect(find.text('Reset to bbbbbbb — hard'), findsOneWidget);
  });

  testWidgets('Tag <short>… opens the Create Tag sheet targeting the clicked '
      'commit', (tester) async {
    await _pump(tester, [head, older], tagSheetProviders: true);

    await tester.tap(find.text('old commit'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tag bbbbbbb…'));
    await tester.pumpAndSettle();

    expect(find.byType(CreateTagSheet), findsOneWidget);
    // The sheet names the exact commit it will tag — not HEAD.
    expect(find.textContaining('bbbbbbb — old commit'), findsOneWidget);
  });

  testWidgets('bulk cherry-pick applies oldest→newest', (tester) async {
    final git = _FakeGit([head, mid, older]);
    await _pump(tester, [head, mid, older], git: git);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await shiftClick(tester, find.text('old commit'));

    await tester.tap(
      find.text('mid commit'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cherry-pick 3 commits'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppPushButton, 'Cherry-pick'));
    await tester.pumpAndSettle();

    expect(git.cherryPicked, [
      'bbbbbbb2222222',
      'ccccccc3333333',
      'aaaaaaa1111111',
    ]);
  });

  testWidgets('bulk revert runs newest→oldest and stops at a conflict', (
    tester,
  ) async {
    final git = _FakeGit([head, mid, older])..conflictOn = 'ccccccc3333333';
    await _pump(tester, [head, mid, older], git: git);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await shiftClick(tester, find.text('old commit'));

    await tester.tap(
      find.text('head commit'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revert 3 commits'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppPushButton, 'Revert'));
    await tester.pumpAndSettle();

    // Newest reverted first; the mid-commit conflict stopped the batch, so
    // the oldest was never attempted.
    expect(git.reverted, ['aaaaaaa1111111']);
    // The conflict surfaced as an error dialog.
    expect(find.textContaining('CONFLICT'), findsOneWidget);
  });

  // ── Minimap ──────────────────────────────────────────────────────────────

  final minimapTrack = find.descendant(
    of: find.byType(HistoryMinimap),
    matching: find.byType(CustomPaint),
  );

  test('minimapVolumeColor ramps cool slate → indigo → blue → soft teal', () {
    final low = minimapVolumeColor(0);
    final midLow = minimapVolumeColor(0.35);
    final mid = minimapVolumeColor(0.65);
    final high = minimapVolumeColor(1);
    final below = minimapVolumeColor(-1);
    final above = minimapVolumeColor(2);
    final between = minimapVolumeColor(0.5);

    // Clamp at the unit interval.
    expect(below, low);
    expect(above, high);

    // Declared stops are hit exactly; mid-ramp values are interpolated.
    expect(low, kMinimapVolumeStops.first.$2);
    expect(high, kMinimapVolumeStops.last.$2);
    expect(midLow, kMinimapVolumeStops[1].$2);
    expect(mid, kMinimapVolumeStops[2].$2);
    expect(between, isNot(midLow));
    expect(between, isNot(mid));

    // Peak alpha stays above quiet; peak is muted teal, not electric cyan.
    expect(high.a, greaterThan(low.a));
    expect(high.a, lessThan(0.55));
    expect(low, isNot(high));
  });

  testWidgets('the minimap stays hidden while the list fits the viewport', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    expect(find.byType(HistoryMinimap), findsOneWidget);
    expect(minimapTrack, findsNothing);
  });

  testWidgets('the minimap appears when the list overflows and jumps on tap', (
    tester,
  ) async {
    // Sixty rows × 52px overflow the test viewport comfortably.
    final many = [
      for (var i = 0; i < 60; i++)
        _c('aaaa${i.toString().padLeft(3, '0')}bbbbfff', 'commit $i'),
    ];
    await _pump(tester, many);
    expect(minimapTrack, findsOneWidget);

    ListView list() => tester.widget<ListView>(find.byType(ListView).first);
    expect(list().controller!.offset, 0);

    // A tap near the track's bottom centers the viewport near the end.
    final rect = tester.getRect(minimapTrack);
    await tester.tapAt(Offset(rect.center.dx, rect.bottom - 2));
    await tester.pumpAndSettle();
    expect(list().controller!.offset, greaterThan(0));
  });

  // ── Zoom ─────────────────────────────────────────────────────────────────

  testWidgets('⌘= zooms the commit list and ⌘0 resets it', (tester) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();

    ListView list() => tester.widget<ListView>(find.byType(ListView).first);
    expect(list().itemExtent, kGraphRowHeight);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(list().itemExtent, moreOrLessEquals(kGraphRowHeight * 1.1));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(list().itemExtent, kGraphRowHeight);
  });

  // ── Filter fields ────────────────────────────────────────────────────────

  final filterToggle = find.byWidgetPredicate(
    (w) => w is MacosIcon && w.icon == CupertinoIcons.slider_horizontal_3,
  );

  testWidgets('the filter fields drive the git log query', (tester) async {
    final git = _FakeGit([head, older]);
    await _pump(tester, [head, older], git: git);

    await tester.tap(filterToggle);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(MacosTextField, 'Author name or email'),
      'alice',
    );
    await tester.enterText(
      find.widgetWithText(MacosTextField, 'After date'),
      '2026-01-01',
    );
    await tester.enterText(
      find.widgetWithText(MacosTextField, 'Limit to a file or folder, e.g. lib/src/'),
      'src/',
    );
    await tester.tap(find.byType(MacosCheckbox)); // hide merges
    // Let the shared 350ms filter debounce land.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(git.lastLogArgs, {
      'grep': null,
      'author': 'alice',
      'since': '2026-01-01',
      'until': null,
      'pathQuery': 'src/',
      'sha': null,
      'all': true,
      'noMerges': true,
    });
    expect(find.textContaining('matching'), findsOneWidget);

    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    // Every criterion reset: the footer disappears and the fields are empty.
    // (No new `git log` fires — the still-cached unfiltered logProvider
    // serves the list again, which is the desired behavior.)
    expect(find.text('Clear filters'), findsNothing);
    expect(
      tester
          .widget<MacosTextField>(
            find.widgetWithText(MacosTextField, 'Author name or email'),
          )
          .controller!
          .text,
      isEmpty,
    );
  });
}
