// Verifies the Stashes namespace renders its list, its empty state, and the
// selected-stash preview. UI/UX polish is validated on macOS; this pins the
// data→render wiring and provider overrides.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
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
  final List<String> applies = [];
  final List<(String?, bool)> pushes = [];
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
  Future<SSHCommandResult> stashApply(String repoPath, String oid) async {
    applies.add(oid);
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
}
