// MADR 0064 F1: at the compact size class (< 720 px of panel width) a
// repository workspace shows one pane at a time. Selecting a row must open the
// canvas WITHOUT trapping the user there: Esc, ⌘[ and the back bar return to
// the list, focus lands where the panel's shortcuts can see it, and the
// selection survives the round trip.
//
// Real input only — taps and key events. Bindings are never invoked directly
// (that bypasses focus routing, which is exactly what failed here), and no
// provider is mutated to fake a state change.
//
// The 1000 px group is the control: standard width shows both panes, so the
// same steps pass on the unmodified tree and prove the instrument works.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';
import 'package:remote_magic_git/features/common/repository_workspace_models.dart';
import 'package:remote_magic_git/features/common/workspace_focus_order.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:remote_magic_git/features/worktrees/worktrees_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_snapshot.dart';

const _repo = '/srv/repo';
const _compact = 600.0;
const _standard = 1000.0;
const _backKey = Key('workspace-compact-back');

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeGit extends GitService with FakeRefsSnapshot {
  _FakeGit({this.commits = const []})
    : super(SSHCommandExecutor(SSHClientManager()));

  final List<GitCommit> commits;
  final List<String> stashApplies = [];
  String? merged;

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
    bool fullHistory = false,
  }) async => commits;

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async => 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';

  @override
  Future<SSHCommandResult> stashApply(
    String repoPath,
    String oid, {
    bool restoreIndex = false,
  }) async {
    stashApplies.add(oid);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
    bool allowUnrelatedHistories = false,
  }) async {
    merged = branch;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

class _QuietGlab extends GlabService {
  _QuietGlab() : super(SSHCommandExecutor(SSHClientManager()));
  int approveCalls = 0;

  @override
  Future<void> approveMergeRequest(String repoPath, int iid) async {
    approveCalls++;
  }
}

class _BrowseMode extends ForgeInboxMode {
  @override
  bool build() => false;
}

class _Connected extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _repo,
    sessionEpoch: 7,
  );
}

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

final _head = _commit('aaaaaaa1111111', 'head commit');
final _older = _commit('bbbbbbb2222222', 'old commit');

const _oidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _oidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _stashes = [
  GitStash(
    index: 0,
    oid: _oidA,
    branch: 'main',
    message: 'WIP on main: abc1234 first',
    relativeDate: '2 hours ago',
  ),
  GitStash(
    index: 1,
    oid: _oidB,
    branch: 'feature',
    message: 'On feature: second',
    relativeDate: '3 days ago',
  ),
];

const _mr = MergeRequest(
  iid: 7,
  title: 'Add the parser',
  state: 'opened',
  authorUsername: 'alice',
  sourceBranch: 'feat',
  targetBranch: 'main',
  webUrl: '',
  draft: false,
  sha: 'abcdef0123456789abcdef0123456789abcdef01',
  detailedMergeStatus: 'mergeable',
  hasConflicts: false,
);

const _worktreeRepo = '/srv/app';
const _worktrees = [
  GitWorktree(
    path: _worktreeRepo,
    headOid: 'a',
    branch: 'refs/heads/main',
    isMain: true,
  ),
  GitWorktree(
    path: '/srv/app-feature',
    headOid: 'b',
    branch: 'refs/heads/feature',
  ),
];

// ---------------------------------------------------------------------------
// Observation helpers
// ---------------------------------------------------------------------------

Finder _region(WorkspacePaneRole role) =>
    find.byWidgetPredicate((w) => w is WorkspaceFocusRegion && w.role == role);

final _navigator = _region(WorkspacePaneRole.navigator);
final _canvas = _region(WorkspacePaneRole.canvas);

BuildContext? get _focusContext => FocusManager.instance.primaryFocus?.context;

String get _focusLabel {
  final node = FocusManager.instance.primaryFocus;
  return '${node?.debugLabel ?? node.runtimeType}';
}

bool get _focusUnderPanelShortcuts =>
    _focusContext?.findAncestorWidgetOfExactType<PanelShortcuts>() != null;

bool get _focusInNavigator =>
    _focusContext
        ?.findAncestorWidgetOfExactType<WorkspaceFocusRegion>()
        ?.role ==
    WorkspacePaneRole.navigator;

void _expectCanvasOnly() {
  expect(_canvas, findsOneWidget, reason: 'canvas must be shown');
  expect(
    _navigator,
    findsNothing,
    reason: 'compact shows one pane: the navigator must be gone',
  );
}

void _expectBothPanes() {
  expect(_navigator, findsOneWidget, reason: 'standard width: navigator');
  expect(_canvas, findsOneWidget, reason: 'standard width: canvas');
}

void _expectFocusUnderPanel() {
  expect(
    _focusUnderPanelShortcuts,
    isTrue,
    reason:
        'primary focus must sit inside the page PanelShortcuts so panel '
        'shortcuts can see key events (focus: $_focusLabel)',
  );
}

void _expectNavigatorFocused(String listLabel) {
  expect(_navigator, findsOneWidget, reason: 'navigator must be shown again');
  expect(
    FocusManager.instance.primaryFocus?.debugLabel,
    listLabel,
    reason: 'focus must return to the list node "$listLabel"',
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  // Rows with a double-tap handler resolve a single tap only after the
  // double-tap window closes.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool alt = false,
  bool shift = false,
}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void _setSize(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _host(
  WidgetTester tester,
  ProviderContainer container,
  double width,
  double height,
  Widget page,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(width: width, height: height, child: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Captures what ⌘C puts on the clipboard.
class _Clipboard {
  String? text;

  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        text = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }
}

// ---------------------------------------------------------------------------
// Page harnesses
// ---------------------------------------------------------------------------

Future<ProviderContainer> _pumpHistory(
  WidgetTester tester,
  double width,
) async {
  _setSize(tester, width, 700);
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit(commits: [_head, _older])),
      repoWatchProvider.overrideWith((ref, repoPath) => const Stream.empty()),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    700,
    const HistoryView(repoPath: _repo, isActive: true),
  );
  return container;
}

Finder get _headRow => find.text('head commit').first;

Future<_FakeGit> _pumpStash(WidgetTester tester, double width) async {
  _setSize(tester, width, 700);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      stashesProvider(_repo).overrideWith((ref) async => _stashes),
      stashDiffProvider((_repo, _oidA)).overrideWith((ref) async => 'PATCH-A'),
      stashDiffProvider((_repo, _oidB)).overrideWith((ref) async => 'PATCH-B'),
    ],
  );
  addTearDown(container.dispose);
  await _host(tester, container, width, 700, const StashView(repoPath: _repo));
  return git;
}

Finder get _firstStash => find.text('first').first;

Future<_FakeGit> _pumpBranches(WidgetTester tester, double width) async {
  _setSize(tester, width, 900);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith(
        (ref) async => const [
          GitRef(name: 'refs/heads/main', oid: 'a', isHead: true, subject: 's'),
          GitRef(
            name: 'refs/heads/feature',
            oid: 'b',
            isHead: false,
            subject: 's',
          ),
        ],
      ),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    900,
    const BranchesView(repoPath: _repo),
  );
  return git;
}

Finder get _featureBranch => find.text('feature').first;

Future<_QuietGlab> _pumpGitLab(WidgetTester tester, double width) async {
  _setSize(tester, width, 800);
  final glab = _QuietGlab();
  final container = ProviderContainer(
    overrides: [
      connectionProvider.overrideWith(_Connected.new),
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      glabServiceProvider.overrideWithValue(glab),
      refsProvider(_repo).overrideWith(
        (ref) async => const [
          GitRef(
            name: 'refs/remotes/origin/main',
            oid: 'deadbeef',
            isHead: false,
            subject: '',
          ),
        ],
      ),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(head: 'main'),
          files: const [],
        ),
      ),
      mergeRequestsProvider(_repo).overrideWith((ref) async => const [_mr]),
      mergeRequestDetailProvider((_repo, 7)).overrideWith((ref) async => _mr),
      repoMergePolicyProvider(
        _repo,
      ).overrideWith((ref) async => const GlRepoMergePolicy()),
      pipelinesProvider(_repo).overrideWith((ref) async => const <Pipeline>[]),
      projectIssuesProvider(_repo).overrideWith((ref) async => const []),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
      projectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
      originRemoteUrlProvider(_repo).overrideWith((ref) async => null),
      changeRequestCommentsProvider((
        _repo,
        7,
      )).overrideWith((ref) async => const []),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    720,
    const GitLabPanel(repoPath: _repo),
  );
  return glab;
}

Finder get _mrRow => find.text('Add the parser').first;

Future<void> _pumpWorktrees(WidgetTester tester, double width) async {
  _setSize(tester, width, 700);
  final container = ProviderContainer(
    overrides: [
      gitWorktreesProvider(
        _worktreeRepo,
      ).overrideWith((ref) async => _worktrees),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    700,
    const WorktreesView(repoPath: _worktreeRepo),
  );
}

Finder get _featureWorktreeRow => find.text('app-feature');

/// The selected overview row is tinted (worktrees_view.dart `_row`).
bool get _featureWorktreeTinted => find
    .ancestor(
      of: _featureWorktreeRow,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.color == MacosColors.systemBlueColor.withValues(alpha: 0.08),
      ),
    )
    .evaluate()
    .isNotEmpty;

void _expectBackBar(String label) {
  expect(find.byKey(_backKey), findsOneWidget, reason: 'back bar button');
  expect(
    find.descendant(of: find.byKey(_backKey), matching: find.text('‹ $label')),
    findsOneWidget,
    reason: 'back bar reads "‹ $label"',
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('compact (600 px)', () {
    group('History', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpHistory(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        _expectFocusUnderPanel();
        _expectBackBar('Commits');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final clipboard = _Clipboard()..install(tester);
        await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('commit-list');
        // The selection survived Back: ⌘C copies the commit that was open.
        await _press(tester, LogicalKeyboardKey.keyC, meta: true);
        expect(clipboard.text, _head.hash, reason: 'selection kept');
        await _tap(tester, _headRow);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('commit-list');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('commit-list');
        await _tap(tester, _headRow);
        _expectCanvasOnly();
      });

      testWidgets('5. ⌘= zooms the commit list from the canvas', (
        tester,
      ) async {
        final container = await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        final before = container.read(appSettingsProvider).historyZoom;
        await _press(tester, LogicalKeyboardKey.equal, meta: true);
        expect(
          container.read(appSettingsProvider).historyZoom,
          greaterThan(before),
          reason: '⌘= must reach History PanelShortcuts (focus: $_focusLabel)',
        );
      });

      testWidgets(
        '8. ↓ in the list moves the selection and stays in the list',
        (tester) async {
          final clipboard = _Clipboard()..install(tester);
          await _pumpHistory(tester, _compact);
          await _tap(tester, _headRow);
          await _press(tester, LogicalKeyboardKey.escape);
          _expectNavigatorFocused('commit-list');
          await _press(tester, LogicalKeyboardKey.arrowDown);
          expect(
            _navigator,
            findsOneWidget,
            reason: 'arrow keys change selection without switching panes',
          );
          await _press(tester, LogicalKeyboardKey.keyC, meta: true);
          expect(
            clipboard.text,
            _older.hash,
            reason: '↓ selected the next row',
          );
        },
      );
    });

    group('Stashes', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpStash(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        expect(find.text('PATCH-A'), findsOneWidget);
        _expectFocusUnderPanel();
        _expectBackBar('Stashes');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final git = await _pumpStash(tester, _compact);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('stash-list');
        // ⌥⌘A applies the selected stash — by the OID that was open.
        await _press(tester, LogicalKeyboardKey.keyA, meta: true, alt: true);
        expect(git.stashApplies, [_oidA], reason: 'selection kept');
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpStash(tester, _compact);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('stash-list');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpStash(tester, _compact);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('stash-list');
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
      });
    });

    group('Branches', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpBranches(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        _expectFocusUnderPanel();
        _expectBackBar('Branches');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final git = await _pumpBranches(tester, _compact);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('branch-list');
        // ⌘⇧M merges the selected branch — the one that was open.
        await _press(tester, LogicalKeyboardKey.keyM, meta: true, shift: true);
        await _tap(tester, find.text('Merge'));
        expect(git.merged, 'feature', reason: 'selection kept');
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpBranches(tester, _compact);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('branch-list');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpBranches(tester, _compact);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('branch-list');
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
      });

      testWidgets(
        '6. the panel keeps exactly one PanelShortcuts in the canvas',
        (tester) async {
          await _pumpBranches(tester, _compact);
          await _tap(tester, _featureBranch);
          _expectCanvasOnly();
          expect(find.byType(PanelShortcuts), findsOneWidget);
        },
      );
    });

    // GitLab rather than GitHub: its harness is already proven by
    // gitlab_panel_test.dart, and approve (⌥⌘A) opens a confirm naming the
    // selected MR's iid, which observes the selection without any mutation.
    group('Forge (GitLab)', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpGitLab(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        _expectFocusUnderPanel();
        _expectBackBar('Items');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final glab = await _pumpGitLab(tester, _compact);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        expect(_navigator, findsOneWidget, reason: 'navigator shown again');
        // Forge has no list node today; the contract is focus inside the
        // navigator and inside the panel's PanelShortcuts.
        expect(_focusInNavigator, isTrue, reason: 'focus: $_focusLabel');
        _expectFocusUnderPanel();
        await _press(tester, LogicalKeyboardKey.keyA, meta: true, alt: true);
        expect(
          find.text('Approve !7 on the remote GitLab project?'),
          findsOneWidget,
          reason: 'selection kept: approve targets the MR that was open',
        );
        await _tap(tester, find.text('Cancel'));
        expect(glab.approveCalls, 0);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpGitLab(tester, _compact);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        expect(_navigator, findsOneWidget, reason: 'navigator shown again');
        expect(_focusInNavigator, isTrue, reason: 'focus: $_focusLabel');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpGitLab(tester, _compact);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        expect(_navigator, findsOneWidget, reason: 'navigator shown again');
        expect(_focusInNavigator, isTrue, reason: 'focus: $_focusLabel');
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
      });
    });

    group('Worktrees', () {
      testWidgets('7. with no selection the list rows are visible', (
        tester,
      ) async {
        await _pumpWorktrees(tester, _compact);
        expect(_navigator, findsOneWidget, reason: 'the list must be shown');
        expect(_featureWorktreeRow, findsOneWidget);
      });

      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpWorktrees(tester, _compact);
        expect(
          _featureWorktreeRow,
          findsOneWidget,
          reason: 'the list must be reachable before a row can be tapped',
        );
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        expect(find.text('Worktree: app-feature'), findsOneWidget);
        _expectFocusUnderPanel();
        _expectBackBar('Worktrees');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        await _pumpWorktrees(tester, _compact);
        expect(_featureWorktreeRow, findsOneWidget, reason: 'list reachable');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('worktree-overview');
        expect(_featureWorktreeTinted, isTrue, reason: 'selection kept');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpWorktrees(tester, _compact);
        expect(_featureWorktreeRow, findsOneWidget, reason: 'list reachable');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('worktree-overview');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpWorktrees(tester, _compact);
        expect(_featureWorktreeRow, findsOneWidget, reason: 'list reachable');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('worktree-overview');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
      });
    });
  });

  group('control (1000 px, standard)', () {
    testWidgets('History 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpHistory(tester, _standard);
      await _tap(tester, _headRow);
      _expectBothPanes();
      _expectFocusUnderPanel();
      expect(find.byKey(_backKey), findsNothing, reason: 'no back bar');
    });

    testWidgets('History 5. ⌘= zooms the commit list', (tester) async {
      final container = await _pumpHistory(tester, _standard);
      await _tap(tester, _headRow);
      final before = container.read(appSettingsProvider).historyZoom;
      await _press(tester, LogicalKeyboardKey.equal, meta: true);
      expect(
        container.read(appSettingsProvider).historyZoom,
        greaterThan(before),
      );
    });

    testWidgets('Stashes 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpStash(tester, _standard);
      await _tap(tester, _firstStash);
      _expectBothPanes();
      expect(find.text('PATCH-A'), findsOneWidget);
      _expectFocusUnderPanel();
    });

    testWidgets('Branches 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpBranches(tester, _standard);
      await _tap(tester, _featureBranch);
      _expectBothPanes();
      _expectFocusUnderPanel();
    });

    testWidgets('Branches 6. exactly one PanelShortcuts', (tester) async {
      await _pumpBranches(tester, _standard);
      await _tap(tester, _featureBranch);
      expect(find.byType(PanelShortcuts), findsOneWidget);
    });

    // Panes only: after a mouse click Forge focus stays outside the panel at
    // every width (MADR 0064 "Forge shortcuts after a mouse click", out of
    // F1's scope), so a focus assertion here would not be a passing control.
    testWidgets('Forge 1. tap keeps both panes', (tester) async {
      await _pumpGitLab(tester, _standard);
      await _tap(tester, _mrRow);
      _expectBothPanes();
    });

    testWidgets('Worktrees 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpWorktrees(tester, _standard);
      expect(_featureWorktreeRow, findsOneWidget);
      await _tap(tester, _featureWorktreeRow);
      _expectBothPanes();
      expect(find.text('Worktree: app-feature'), findsOneWidget);
      _expectFocusUnderPanel();
    });
  });
}
