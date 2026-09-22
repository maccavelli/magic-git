// Regression coverage for the branch-delete force escalation: a plain delete
// that git rejects as "not fully merged" used to just dead-end with a raw
// error dialog, even though GitService.deleteBranch(force: true) already
// existed — it was simply never wired to anything. Now it offers a follow-up
// force-delete confirmation.

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/workspace_focus.dart';
import 'package:remote_magic_git/features/common/workspace_navigation.dart';
import 'package:remote_magic_git/features/dnd/deselect.dart';
import 'package:riverpod/misc.dart' show Override;

const _repo = '/repo';

const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: 'aaa',
    isHead: true,
    subject: 'head commit',
  ),
  GitRef(
    name: 'refs/heads/feature',
    oid: 'bbb',
    isHead: false,
    subject: 'feature commit',
  ),
  GitRef(
    name: 'refs/remotes/origin/feature',
    oid: 'bbb',
    isHead: false,
    subject: 'feature commit',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<bool> forceCalls = [];

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    forceCalls.add(force);
    if (!force) {
      throw const GitException(
        'git branch -d failed',
        SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr:
              "error: The branch 'feature' is not fully merged.\n"
              "If you are sure you want to delete it, run 'git branch -D "
              "feature'.",
        ),
      );
    }
  }
}

// Actions moved off the rows into a right-click context menu + the detail
// pane; open a row's menu with a secondary (right) click.
Future<void> _rightClick(WidgetTester tester, Finder f) =>
    tester.tap(f, buttons: kSecondaryButton, warnIfMissed: false);

List<Override> _overrides(_FakeGit git) => [
  gitServiceProvider.overrideWithValue(git),
  refsProvider(_repo).overrideWith((ref) async => _refs),
  // The view now watches CONFIGURED remotes to pick the tag-push target
  // — unoverridden it would fall through to the executor.
  remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
  // The real provider keeps a five-minute keepAlive timer that widget
  // tests would flag as still pending; null = unknown, no badges.
  remoteTagsProvider(_repo).overrideWith((ref) async => null),
  branchForgeProvider(_repo).overrideWith((ref) async => const {}),
  mergedBranchesProvider(_repo).overrideWith((ref) async => const <String>{}),
];

Future<_FakeGit> _pump(WidgetTester tester) async {
  final git = _FakeGit();
  final container = ProviderContainer(overrides: _overrides(git));
  addTearDown(container.dispose);
  await tester.pumpWidget(_tree(container, isActive: true));
  await tester.pumpAndSettle();
  return git;
}

/// The harness with a live session, so navigation recording applies; returns
/// the container so a test can read the session's history.
Future<ProviderContainer> _pumpForNavigation(
  WidgetTester tester, {
  required bool isActive,
}) async {
  final container = ProviderContainer(
    overrides: [
      ..._overrides(_FakeGit()),
      connectionProvider.overrideWith(
        () => _StubConnection(
          const ConnectionState(
            phase: ConnectionPhase.connected,
            repoPath: _repo,
            sessionEpoch: 1,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(_tree(container, isActive: isActive));
  await tester.pumpAndSettle();
  return container;
}

/// The harness tree, so a test can pump it again unchanged — the way the app
/// shell rebuilds every page when it rebuilds itself (0065-MADR).
Widget _tree(ProviderContainer container, {required bool isActive}) {
  return UncontrolledProviderScope(
    container: container,
    child: MacosApp(
      debugShowCheckedModeBanner: false,
      home: BranchesView(repoPath: _repo, isActive: isActive),
    ),
  );
}

Future<void> _openAdvancedMenu(WidgetTester tester) async {
  // Delete (and other overflow actions) live under the Advanced pulldown.
  if (find.text('Delete').evaluate().isEmpty &&
      find.text('Advanced').evaluate().isNotEmpty) {
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
  }
}

void main() {
  // 0065: a panel records its location once per change, only while active.
  bool branchSelected(ProviderContainer container) => container
      .read(repositoryContextSupplementCacheProvider)
      .values
      .any((s) => s.branchLabel == 'Selected: feature');

  testWidgets('records a branch once: a rebuild after a foreign visit adds '
      'nothing (0065)', (tester) async {
    final container = await _pumpForNavigation(tester, isActive: true);
    const key = WorkspaceSessionKey(_repo, 1);
    final history = container.read(workspaceNavigationProvider(key).notifier);

    await tester.tap(find.text('feature'));
    await tester.pump();
    await tester.pump();
    expect(branchSelected(container), isTrue, reason: 'the tap selected it');
    final recorded = container.read(workspaceNavigationProvider(key)).locations;
    expect(recorded, hasLength(1), reason: 'selecting a branch records once');
    expect(recorded.single.kind, WorkspaceFocusKind.branch);
    expect(recorded.single.identity, 'refs/heads/feature');
    expect(recorded.single.panelIndex, 2);

    // Another panel records where the user went; the shell then rebuilds
    // every page, this one included. A rebuild is not a visit.
    const commit = WorkspaceFocus(
      repositoryPath: _repo,
      sessionEpoch: 1,
      kind: WorkspaceFocusKind.revision,
      identity: 'abc123',
      panelIndex: 1,
    );
    history.visit(commit);
    await tester.pumpWidget(_tree(container, isActive: true));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final nav = container.read(workspaceNavigationProvider(key));
    expect(nav.locations, [
      recorded.single,
      commit,
    ], reason: 'an unchanged selection must not be re-recorded on rebuild');
    expect(nav.index, 1);
  });

  testWidgets('records nothing while it is not the active page (0065)', (
    tester,
  ) async {
    final container = await _pumpForNavigation(tester, isActive: false);
    const key = WorkspaceSessionKey(_repo, 1);

    await tester.tap(find.text('feature'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(branchSelected(container), isTrue, reason: 'the tap selected it');
    expect(
      container.read(workspaceNavigationProvider(key)).locations,
      isEmpty,
      reason: 'a hidden panel never records where the user is',
    );
  });

  testWidgets('a branch rejected as "not fully merged" offers a force-delete '
      'confirmation, which retries with force: true', (tester) async {
    final git = await _pump(tester);

    // Right-click the local branch → Delete branch (menu item).
    await _rightClick(tester, find.text('feature'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete branch'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Delete branch'), findsWidgets);

    // Confirm the plain delete — it fails as "not fully merged".
    await _openAdvancedMenu(tester);
    await tester.tap(find.text('Delete').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(git.forceCalls, [false]);
    expect(find.text('Branch not fully merged'), findsOneWidget);

    // Confirm the force-delete escalation.
    await tester.tap(find.text('Force Delete'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(git.forceCalls, [false, true]);
  });

  testWidgets('cancelling the force-delete escalation does not retry', (
    tester,
  ) async {
    final git = await _pump(tester);

    await _rightClick(tester, find.text('feature'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete branch'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _openAdvancedMenu(tester);
    await tester.tap(find.text('Delete').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Branch not fully merged'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(git.forceCalls, [false]);
  });

  testWidgets(
    'double-tapping a checkout affordance while one is in flight fires only '
    'one checkout — the second would otherwise run against whatever branch '
    'the first one lands on',
    (tester) async {
      final gate = Completer<void>();
      final git = _GatedCheckoutGit(gate);
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          refsProvider(_repo).overrideWith((ref) async => _refs),
          // The view now watches CONFIGURED remotes to pick the tag-push target
          // — unoverridden it would fall through to the executor.
          remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
          // The real provider keeps a five-minute keepAlive timer that widget
          // tests would flag as still pending; null = unknown, no badges.
          remoteTagsProvider(_repo).overrideWith((ref) async => null),
          branchForgeProvider(_repo).overrideWith((ref) async => const {}),
          mergedBranchesProvider(
            _repo,
          ).overrideWith((ref) async => const <String>{}),
          // Clean status — guardedBranchSwitch runs the checkout directly
          // with no confirm dialog in the way.
          statusProvider(_repo).overrideWith(
            (ref) async =>
                GitStatus(branch: const GitBranchInfo(), files: const []),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: BranchesView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Select the local branch, then double-tap its detail-pane Check out
      // button: the first checkout marks the panel busy, disabling the button,
      // so the second tap is inert.
      await tester.tap(find.text('feature'));
      await tester.pumpAndSettle();
      final checkoutBtn = find.text('Check out');
      await tester.tap(checkoutBtn);
      await tester.pump();
      await tester.tap(checkoutBtn); // fired while the first is still gated
      await tester.pump();

      expect(git.checkoutCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(git.checkoutCalls, 1, reason: 'still exactly one checkout call');
    },
  );

  // Canonical deselect affordances (see lib/features/dnd/deselect.dart).
  Finder selectedRows() => find.byWidgetPredicate(
    (w) => w is Container && w.color == AppTheme.rowSelectionTint,
  );

  testWidgets('Esc deselects the selected branch', (tester) async {
    await _pump(tester);

    // Exact match hits only the local row ('origin/feature' is the remote's).
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(selectedRows(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(selectedRows(), findsNothing);
  });

  testWidgets('a click on empty list space deselects the branch', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(selectedRows(), findsOneWidget);

    // Below the last row: inside the list, on nothing.
    final rect = tester.getRect(find.byType(DeselectOnEmptyClick));
    await tester.tapAt(Offset(rect.left + 24, rect.bottom - 12));
    await tester.pumpAndSettle();
    expect(selectedRows(), findsNothing);
  });
}

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

class _GatedCheckoutGit extends GitService {
  _GatedCheckoutGit(this._gate) : super(SSHCommandExecutor(SSHClientManager()));
  final Completer<void> _gate;
  int checkoutCalls = 0;

  @override
  Future<void> checkout(String repoPath, String ref) async {
    checkoutCalls++;
    await _gate.future;
  }
}
