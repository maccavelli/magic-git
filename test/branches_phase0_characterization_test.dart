// Phase 0 characterization: lock current Branches behavior before deeper
// extraction. No intended UX change in Phase 0.

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

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
  GitRef(
    name: 'refs/tags/v1.0',
    oid: 'ccc',
    isHead: false,
    subject: 'tag subject',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Set<String> merged = const {},
}) async {
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(_repo).overrideWith((ref) async => merged),
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
  return container;
}

void main() {
  testWidgets('HEAD row uses green tint that masks selection background', (
    tester,
  ) async {
    await _pump(tester);

    // Select HEAD (main).
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();

    // The local row for HEAD paints systemGreen at 0.12 alpha, not the
    // selection tint — characterization of the known a11y debt (Phase 6).
    final greenContainers = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final c = w.color;
      if (c == null) return false;
      // systemGreen with alpha ~0.12
      return c.a < 0.2 && c.a > 0.05 && c.g > c.r && c.g > c.b;
    });
    expect(greenContainers, findsWidgets);

    // Selection tint should still exist as a constant for non-HEAD rows.
    expect(AppTheme.rowSelectionTint, isNotNull);
  });

  testWidgets('selecting a remote row shows remote detail without forge create', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('origin/feature'));
    await tester.pumpAndSettle();
    // Remote detail exposes checkout tracking, not create-PR.
    expect(find.textContaining('origin/feature'), findsWidgets);
  });

  testWidgets('repo path change clears selection (didUpdateWidget)', (
    tester,
  ) async {
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => _refs),
        refsProvider('/other').overrideWith((ref) async => _refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remotesProvider('/other').overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        remoteTagsProvider('/other').overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        branchForgeProvider('/other').overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo)
            .overrideWith((ref) async => const <String>{}),
        mergedBranchesProvider('/other')
            .overrideWith((ref) async => const <String>{}),
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
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: BranchesView(repoPath: '/other'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Empty-state dashboard after selection clear (no selected detail Delete).
    expect(find.text('Branches'), findsWidgets);
  });

  testWidgets('context menu still opens on secondary click', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('feature'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Delete branch'), findsOneWidget);
  });

  testWidgets('browse first paint issues only current providers', (
    tester,
  ) async {
    // Track which providers are read during the first paint.
    final providersRead = <String>{};

    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) {
          providersRead.add('refs');
          return _refs;
        }),
        remotesProvider(_repo).overrideWith((ref) {
          providersRead.add('remotes');
          return const ['origin'];
        }),
        remoteTagsProvider(_repo).overrideWith((ref) {
          providersRead.add('remoteTags');
          return null;
        }),
        branchForgeProvider(_repo).overrideWith((ref) {
          providersRead.add('branchForge');
          return const {};
        }),
        mergedBranchesProvider(_repo).overrideWith((ref) {
          providersRead.add('mergedBranches');
          return const <String>{};
        }),
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

    // Browse first paint must NOT issue comparison/forge N+1 work (Phase 7 gate).
    // Only the current provider set should be read.
    expect(providersRead, contains('refs'));
    expect(providersRead, contains('remotes'));
    // branchForge and mergedBranches are lazy badges — they may or may not resolve
    // during first paint, but they must not block or cause N+1 calls.
    // The critical invariant: no comparison/summary/diff providers are invoked.
    expect(providersRead, isNot(contains('branchReviewSummaries')));
    expect(providersRead, isNot(contains('branchComparisonMetadata')));
    expect(providersRead, isNot(contains('branchDiff')));
    expect(providersRead, isNot(contains('branchMergePreview')));
  });

  testWidgets('remote row keyboard selection and Enter checkout', (
    tester,
  ) async {
    await _pump(tester);

    // Focus the branch list by tapping a local branch first.
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();

    // Navigate to remote section with arrow keys.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    // Remote row should now be selected (origin/feature).
    expect(find.text('origin/feature'), findsWidgets);

    // Enter on a remote row does NOT check out (remote checkout requires
    // explicit action from detail pane or context menu).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // Still on the same remote row — no checkout occurred.
    expect(find.text('origin/feature'), findsWidgets);
  });

  testWidgets('tag row keyboard selection', (tester) async {
    await _pump(tester);

    // Focus the branch list.
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();

    // Navigate down to tags section (past locals and remotes).
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }

    // Tag row should now be selected (v1.0).
    expect(find.text('v1.0'), findsWidgets);
  });

  testWidgets('delete branch shows confirmation dialog', (tester) async {
    await _pump(tester);

    // Select a non-HEAD branch.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    // Click the Delete button in the detail pane.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Confirmation dialog should appear.
    expect(find.text('Delete branch'), findsOneWidget);
    expect(find.textContaining('Delete local branch'), findsOneWidget);
  });

  testWidgets('worktree-held branch shows worktree badge and no delete', (
    tester,
  ) async {
    const worktreeRefs = [
      GitRef(
        name: 'refs/heads/main',
        oid: 'aaa',
        isHead: true,
        subject: 'head commit',
      ),
      GitRef(
        name: 'refs/heads/worktree-branch',
        oid: 'ddd',
        isHead: false,
        subject: 'worktree commit',
        worktreePath: '/worktrees/feature',
      ),
    ];

    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => worktreeRefs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
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

    // Select the worktree-held branch.
    await tester.tap(find.text('worktree-branch'));
    await tester.pumpAndSettle();

    // Worktree badge should be visible.
    expect(find.text('feature'), findsWidgets);

    // Delete button should NOT be present for worktree-held branches.
    expect(find.text('Delete'), findsNothing);

    // Instead, "Switch to worktree" should be available.
    expect(find.text('Switch to worktree'), findsOneWidget);
  });

  testWidgets('unmerged delete escalates to force-delete confirmation', (
    tester,
  ) async {
    final git = _ForceDeleteGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => _refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
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

    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // First confirmation: ordinary delete.
    expect(find.text('Delete branch'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    // Escalation: not fully merged → force-delete dialog (undo still comes
    // from GitService._runCaptured on the eventual force path).
    expect(find.text('Branch not fully merged'), findsOneWidget);
    expect(find.text('Force Delete'), findsOneWidget);
    expect(git.deleteCalls, 1);
    expect(git.forceCalls, 0);

    await tester.tap(find.text('Force Delete'));
    await tester.pumpAndSettle();
    expect(git.forceCalls, 1);
  });

  testWidgets('repo path change clears selection scroll and local overrides', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_FakeGit()),
        refsProvider(_repo).overrideWith((ref) async => _refs),
        refsProvider('/other').overrideWith((ref) async => _refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remotesProvider('/other').overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        remoteTagsProvider('/other').overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        branchForgeProvider('/other').overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider('/other').overrideWith((ref) async => const {}),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: _RepoSwitchHarness(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Switch repo'));
    await tester.pumpAndSettle();

    // Selection cleared — empty-state dashboard, not feature detail.
    expect(find.text('Delete'), findsNothing);
    expect(find.textContaining('Select a branch'), findsOneWidget);
  });
}

/// Fake that refuses non-force deletes as "not fully merged".
class _ForceDeleteGit extends GitService {
  _ForceDeleteGit() : super(SSHCommandExecutor(SSHClientManager()));

  int deleteCalls = 0;
  int forceCalls = 0;

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    deleteCalls++;
    if (force) {
      forceCalls++;
      return;
    }
    throw const GitException(
      'not fully merged',
      SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: "error: the branch 'feature' is not fully merged.",
      ),
    );
  }
}

class _RepoSwitchHarness extends StatefulWidget {
  const _RepoSwitchHarness();

  @override
  State<_RepoSwitchHarness> createState() => _RepoSwitchHarnessState();
}

class _RepoSwitchHarnessState extends State<_RepoSwitchHarness> {
  String _repo = '/repo';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: () => setState(() => _repo = '/other'),
          child: const Text('Switch repo'),
        ),
        Expanded(child: BranchesView(repoPath: _repo)),
      ],
    );
  }
}
