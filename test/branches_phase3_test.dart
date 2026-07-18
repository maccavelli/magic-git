// Phase-3 differentiators on the Branches tab: the single-branch linear commit
// view in the detail pane, the empty-state review dashboard's one-click
// "delete merged" cleanup, and keyboard navigation across all sections.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';

const _repo = '/repo';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(name: 'refs/heads/feature', oid: 'bbb', isHead: false, subject: 's'),
  GitRef(name: 'refs/heads/other', oid: 'ccc', isHead: false, subject: 's'),
  GitRef(name: 'refs/remotes/origin/topic', oid: 'ddd', isHead: false, subject: 's'),
  GitRef(name: 'refs/tags/v1', oid: 'eee', isHead: false, subject: 's'),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final deleted = <String>[];

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    deleted.add(name);
  }
}

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-10T10:00:00Z',
  parents: const ['p'],
  subject: subject,
);

Future<_FakeGit> _pump(
  WidgetTester tester, {
  List<GitRef> refs = _refs,
  Set<String> merged = const {},
  Map<(String, String), List<GitCommit>> commits = const {},
}) async {
  tester.view.physicalSize = const Size(1500, 1300);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(_repo).overrideWith((ref) async => merged),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(branch: const GitBranchInfo(), files: const []),
      ),
      for (final e in commits.entries)
        branchCommitsProvider(e.key).overrideWith((ref) async => e.value),
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
  return git;
}

void main() {
  testWidgets('the detail pane shows the selected branch\'s recent commits', (
    tester,
  ) async {
    await _pump(
      tester,
      commits: {
        (_repo, 'feature'): [
          _commit('abcdef1234', 'Wire the thing'),
          _commit('bbccdd5678', 'Add a test'),
        ],
      },
    );

    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    expect(find.text('RECENT COMMITS'), findsOneWidget);
    expect(find.text('Wire the thing'), findsOneWidget);
    expect(find.text('Add a test'), findsOneWidget);
  });

  testWidgets('the review dashboard deletes all merged branches in one action',
      (tester) async {
    final git = await _pump(tester, merged: const {'feature', 'other'});

    // Nothing selected → the dashboard, with the merged-cleanup action.
    expect(find.text('Branches'), findsOneWidget);
    final deleteBtn = find.widgetWithText(InlineActionButton, 'Delete 2 merged…');
    expect(deleteBtn, findsOneWidget);

    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();
    // Confirm.
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(git.deleted, containsAll(<String>['feature', 'other']));
    expect(git.deleted, isNot(contains('main')), reason: 'HEAD is never merged-deletable');
  });

  testWidgets('arrow keys walk across local, remote and tag sections', (
    tester,
  ) async {
    await _pump(tester);

    // Select a local branch, then arrow down into the remote section.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    // feature → other → origin/topic (remote). Two downs.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    // The detail pane now shows the remote's action — nav crossed sections.
    expect(
      find.widgetWithText(InlineActionButton, 'Check out tracking branch'),
      findsOneWidget,
    );
  });
}
