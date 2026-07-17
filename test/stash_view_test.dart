// Verifies the Stashes namespace renders its list, its empty state, and the
// selected-stash preview. UI/UX polish is validated on macOS; this pins the
// data→render wiring and provider overrides.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/dnd/deselect.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Executor that never touches SSH — the view reads gitServiceProvider in build
/// but the render tests never fire a mutation.
class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor() : super(SSHClientManager());
  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) async => const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
}

/// Captures the view's mutation wiring — which identity each action hands
/// the service — without touching SSH.
class _ActionGit extends GitService {
  _ActionGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<(int, String)> drops = [];
  final List<(int, String)> pops = [];
  final List<bool> popRestoreIndex = [];
  final List<String> applies = [];
  final List<bool> applyRestoreIndex = [];
  final List<(String?, bool)> pushes = [];
  final List<(String, int, String)> branches = []; // (name, index, oid)
  bool cleared = false;
  bool stale = false;

  @override
  Future<SSHCommandResult> stashDrop(
    String repoPath,
    int index, {
    required String expectedOid,
  }) async {
    if (stale) throw const StashStaleException();
    drops.add((index, expectedOid));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashPop(
    String repoPath,
    int index, {
    required String expectedOid,
    bool restoreIndex = false,
  }) async {
    if (stale) throw const StashStaleException();
    pops.add((index, expectedOid));
    popRestoreIndex.add(restoreIndex);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashClear(String repoPath) async {
    cleared = true;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashApply(
    String repoPath,
    String oid, {
    bool restoreIndex = false,
  }) async {
    applies.add(oid);
    applyRestoreIndex.add(restoreIndex);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashBranch(
    String repoPath,
    String branchName, {
    required int index,
    required String expectedOid,
  }) async {
    branches.add((branchName, index, expectedOid));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashPush(
    String repoPath, {
    String? message,
    bool includeUntracked = false,
    List<String> paths = const [],
  }) async {
    pushes.add((message, includeUntracked));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

const _repo = '/repo';

const _oidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _oidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final _stashes = [
  const GitStash(
    index: 0,
    oid: _oidA,
    branch: 'main',
    message: 'WIP on main: abc1234 tweak the parser',
    relativeDate: '2 hours ago',
  ),
  const GitStash(
    index: 1,
    oid: _oidB,
    branch: 'feature',
    message: 'On feature: manual note',
    relativeDate: '3 days ago',
  ),
];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<GitStash> stashes,
  GitService? git,
  String stashDiff = 'diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n',
}) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git ?? GitService(_FakeExecutor())),
      stashesProvider(_repo).overrideWith((ref) async => stashes),
      stashDiffProvider((_repo, _oidA)).overrideWith((ref) async => stashDiff),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 1000,
          height: 700,
          child: StashView(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('renders a card per stash with subject, ref, branch, and age', (
    tester,
  ) async {
    await _pump(tester, stashes: _stashes);

    expect(find.text('Stashes'), findsOneWidget);
    // subject strips the "WIP on <branch>: <sha> " boilerplate.
    expect(find.text('tweak the parser'), findsOneWidget);
    expect(find.text('manual note'), findsOneWidget);
    expect(find.text('stash@{0}'), findsOneWidget);
    expect(find.text('stash@{1}'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.textContaining('2 hours ago'), findsOneWidget);
    // Nothing selected yet — the preview shows its placeholder.
    expect(
      find.text('Select a stash to preview its contents'),
      findsOneWidget,
    );
  });

  testWidgets('the stash-list divider drags and persists its width', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // The mock prefs store is process-static: without this reset the width
    // persisted below would leak into the OTHER tests in this file (whose
    // _pump does not reseed prefs) and shift their layout.
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await _pump(tester, stashes: _stashes);

    final gesture = await tester.startGesture(
      const Offset(360.5, 300), // the divider (stashList default width)
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_stashList'), 380);
  });

  testWidgets('shows the empty state when there are no stashes', (tester) async {
    await _pump(tester, stashes: const []);
    expect(find.text('No stashes'), findsOneWidget);
    expect(find.textContaining('stash your current changes'), findsOneWidget);
  });

  testWidgets('drop confirms destructively, then hands the service the '
      'index AND the rendered OID', (tester) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
      ).first,
    );
    await tester.pumpAndSettle();

    expect(git.drops, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();

    expect(git.drops, [(0, _oidA)]);
  });

  testWidgets('a stale drop explains itself instead of a raw git error', (
    tester,
  ) async {
    final git = _ActionGit()..stale = true;
    await _pump(tester, stashes: _stashes, git: git);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
      ).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();

    expect(find.textContaining('stash list changed'), findsOneWidget);
    expect(git.drops, isEmpty);
  });

  testWidgets('apply addresses the stash by OID', (tester) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.tray_arrow_up,
      ).last,
    );
    await tester.pumpAndSettle();

    expect(git.applies, [_oidB]);
  });

  testWidgets('Stash with message prompts, then pushes with untracked '
      'included', (tester) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);

    await tester.tap(find.byType(MacosPulldownButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stash with message\u2026'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(MacosTextField).last, 'my parked work');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(git.pushes, [('my parked work', true)]);
  });

  testWidgets('selecting a stash previews its patch', (tester) async {
    await _pump(tester, stashes: _stashes);
    await tester.tap(find.text('tweak the parser'));
    await tester.pumpAndSettle();

    // The placeholder is replaced by the stash's diff content.
    expect(
      find.text('Select a stash to preview its contents'),
      findsNothing,
    );
    expect(find.textContaining('@@ -1 +1 @@'), findsOneWidget);
  });

  // Canonical deselect affordances (see lib/features/dnd/deselect.dart).
  testWidgets('Esc clears the stash selection', (tester) async {
    await _pump(tester, stashes: _stashes);
    await tester.tap(find.text('tweak the parser'));
    await tester.pumpAndSettle();
    expect(find.text('Select a stash to preview its contents'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Select a stash to preview its contents'), findsOneWidget);
  });

  testWidgets('a click on empty list space clears the stash selection', (
    tester,
  ) async {
    await _pump(tester, stashes: _stashes);
    await tester.tap(find.text('tweak the parser'));
    await tester.pumpAndSettle();
    expect(find.text('Select a stash to preview its contents'), findsNothing);

    // Below the two cards: inside the master list pane, on nothing.
    final rect = tester.getRect(find.byType(DeselectOnEmptyClick));
    await tester.tapAt(Offset(rect.left + 24, rect.bottom - 12));
    await tester.pumpAndSettle();
    expect(find.text('Select a stash to preview its contents'), findsOneWidget);
  });

  // ---- Header hamburger menu (stash-wide actions) --------------------------

  Future<void> openMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byType(MacosPulldownButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  testWidgets('"Stash current changes" pushes with no message, tracked only', (
    tester,
  ) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openMenu(tester, 'Stash current changes');
    expect(git.pushes, [(null, false)]);
  });

  testWidgets('"Stash including untracked" pushes with untracked included', (
    tester,
  ) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openMenu(tester, 'Stash including untracked');
    expect(git.pushes, [(null, true)]);
  });

  testWidgets('"Apply latest stash" applies the top entry by OID', (
    tester,
  ) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openMenu(tester, 'Apply latest stash');
    // Latest = stash@{0} = _oidA, read at tap time.
    expect(git.applies, [_oidA]);
  });

  testWidgets('"Pop latest stash" pops the top entry with its index and OID', (
    tester,
  ) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openMenu(tester, 'Pop latest stash');
    expect(git.pops, [(0, _oidA)]);
  });

  testWidgets('"Clear all stashes" confirms destructively, then clears', (
    tester,
  ) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openMenu(tester, 'Clear all stashes…');

    expect(git.cleared, isFalse, reason: 'nothing before the confirm');
    await tester.tap(find.text('Clear All'));
    await tester.pumpAndSettle();
    expect(git.cleared, isTrue);
  });

  testWidgets('with no stashes, act-on-existing menu items are disabled but '
      'stashing stays enabled', (tester) async {
    await _pump(tester, stashes: const []);
    await tester.tap(find.byType(MacosPulldownButton));
    await tester.pumpAndSettle();

    // Inspect the built items' onTap directly — a null handler is the disabled
    // state (tapping a disabled item has unreliable dismiss behavior to assert
    // against).
    MacosPulldownMenuItem itemFor(String title) => tester
        .widgetList<MacosPulldownMenuItem>(find.byType(MacosPulldownMenuItem))
        .firstWhere((i) => i.title is Text && (i.title as Text).data == title);

    expect(itemFor('Apply latest stash').onTap, isNull);
    expect(itemFor('Pop latest stash').onTap, isNull);
    expect(itemFor('Clear all stashes…').onTap, isNull);
    // Stashing the current tree doesn't require an existing stash.
    expect(itemFor('Stash current changes').onTap, isNotNull);
    expect(itemFor('Stash including untracked').onTap, isNotNull);
  });

  // ---- Card right-click menu (--index variants + create-branch) -----------

  Future<void> openCardMenu(WidgetTester tester, String cardText) async {
    await tester.tap(find.text(cardText), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  testWidgets('right-click a card offers the --index variants and create-branch',
      (tester) async {
    await _pump(tester, stashes: _stashes);
    await openCardMenu(tester, 'tweak the parser');
    expect(find.text('Apply, restoring staged files'), findsOneWidget);
    expect(find.text('Pop, restoring staged files'), findsOneWidget);
    expect(find.text('Create branch from stash…'), findsOneWidget);
  });

  testWidgets('"Apply, restoring staged files" applies that stash with --index',
      (tester) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openCardMenu(tester, 'tweak the parser'); // stash@{0} = _oidA
    await tester.tap(find.text('Apply, restoring staged files'));
    await tester.pumpAndSettle();
    expect(git.applies, [_oidA]);
    expect(git.applyRestoreIndex, [true]);
  });

  testWidgets('"Pop, restoring staged files" pops that stash with --index',
      (tester) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openCardMenu(tester, 'manual note'); // stash@{1} = _oidB
    await tester.tap(find.text('Pop, restoring staged files'));
    await tester.pumpAndSettle();
    expect(git.pops, [(1, _oidB)]);
    expect(git.popRestoreIndex, [true]);
  });

  testWidgets('"Create branch from stash…" prompts then calls stashBranch',
      (tester) async {
    final git = _ActionGit();
    await _pump(tester, stashes: _stashes, git: git);
    await openCardMenu(tester, 'tweak the parser'); // stash@{0}, index 0, _oidA
    await tester.tap(find.text('Create branch from stash…'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(MacosTextField).last, 'recovered');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(git.branches, [('recovered', 0, _oidA)]);
  });
}
