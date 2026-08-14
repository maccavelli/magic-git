// The Branches → History handoff must seed the mount it actually navigates.
//
// `_openHistory` drives the MAIN shell's page stack (pageIndexProvider /
// visitedPagesProvider), but BranchesView is also embedded per-worktree
// (worktrees_view.dart mounts it with the worktree path). Seeding
// `widget.repoPath` from there produced an intent the main HistoryView rejects
// on its mount check — and, crucially, does NOT clear — so the click looked
// inert and the stale intent was silently consumed later by that worktree's
// own History sub-page, filtering an unrelated view.

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/tabs/tab_ui_providers.dart';

const _mainRepo = '/repo';
const _worktree = '/repo-worktrees/feature';

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
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
}

/// The main shell is connected to [_mainRepo] — that is the mount whose page
/// stack `_openHistory` drives, whatever path this view was constructed with.
class _Connected extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _mainRepo,
    sessionEpoch: 1,
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required String mountRepoPath,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit()),
      connectionProvider.overrideWith(_Connected.new),
      for (final repo in {_mainRepo, mountRepoPath}) ...[
        refsProvider(repo).overrideWith((ref) async => _refs),
        remotesProvider(repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(repo).overrideWith((ref) async => null),
        branchForgeProvider(repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider(repo).overrideWith((ref) async => const {}),
      ],
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: BranchesView(repoPath: mountRepoPath),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openHistoryFor(WidgetTester tester, String branch) async {
  await tester.tap(find.text(branch));
  await tester.pumpAndSettle();
  if (find.text('Open reachable history').evaluate().isEmpty &&
      find.text('More').evaluate().isNotEmpty) {
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Open reachable history'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('from the main mount, the intent targets the main repo', (
    tester,
  ) async {
    final container = await _pump(tester, mountRepoPath: _mainRepo);

    await _openHistoryFor(tester, 'feature');

    final intent = container.read(historyNavigationIntentProvider);
    expect(intent, isNotNull);
    expect(intent!.repoPath, _mainRepo);
    expect(intent.revision, 'feature');
  });

  testWidgets('from a worktree-embedded mount, the intent still targets the '
      'main repo — the mount whose page stack is being driven', (tester) async {
    final container = await _pump(tester, mountRepoPath: _worktree);

    await _openHistoryFor(tester, 'feature');

    final intent = container.read(historyNavigationIntentProvider);
    expect(intent, isNotNull);
    expect(
      intent!.repoPath,
      _mainRepo,
      reason: 'seeding the worktree path leaves an intent the main History '
          'mount rejects without clearing, which a later worktree History '
          'view then silently consumes',
    );
    expect(intent.revision, 'feature');
  });

  testWidgets('the History page is selected and marked visited', (
    tester,
  ) async {
    final container = await _pump(tester, mountRepoPath: _worktree);

    await _openHistoryFor(tester, 'feature');

    // History is nav index 1 (DropZoneId.history); asserted by value here so a
    // rail reorder that desyncs the two is caught.
    expect(container.read(pageIndexProvider), 1);
    expect(container.read(visitedPagesProvider), contains(1));
  });
}
