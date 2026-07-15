// The Branches panel's newer affordances: upstream-divergence badges, rename,
// delete-on-remote, and the fast-forward-only merge item.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';

const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: 'aaa',
    isHead: true,
    upstream: 'origin/main',
    subject: 's',
    ahead: 2,
    behind: 1,
  ),
  GitRef(
    name: 'refs/heads/stale',
    oid: 'bbb',
    isHead: false,
    upstream: 'origin/stale',
    subject: 's',
    upstreamGone: true,
  ),
  GitRef(
    name: 'refs/remotes/origin/feature',
    oid: 'ccc',
    isHead: false,
    subject: 's',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<(String, String)> renames = [];
  final List<(String, String)> remoteDeletes = [];
  final List<MergeMode> merges = [];

  @override
  Future<void> renameBranch(
    String repoPath,
    String oldName,
    String newName,
  ) async {
    renames.add((oldName, newName));
  }

  @override
  Future<SSHCommandResult> deleteRemoteBranch(
    String repoPath,
    String remote,
    String branch,
  ) async {
    remoteDeletes.add((remote, branch));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) async {
    merges.add(mode);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<_FakeGit> _pump(WidgetTester tester) async {
  final git = _FakeGit();
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
  testWidgets('divergence badges: ↑/↓ for a diverged branch, "gone" for a '
      'deleted upstream', (tester) async {
    await _pump(tester);

    expect(find.text('↑2 ↓1'), findsOneWidget);
    expect(find.text('gone'), findsOneWidget);
  });

  testWidgets('rename prompts with the current name and calls the service', (
    tester,
  ) async {
    final git = await _pump(tester);

    // The current branch is renameable too — tap its pencil.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.pencil,
      ).first,
    );
    await tester.pumpAndSettle();

    // Pre-filled with the old name; replace and confirm.
    await tester.enterText(find.byType(MacosTextField).last, 'trunk');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(git.renames, [('main', 'trunk')]);
  });

  testWidgets('deleting a remote branch confirms, then pushes the delete', (
    tester,
  ) async {
    final git = await _pump(tester);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
      ).last, // the remote row's — local rows render above it
    );
    await tester.pumpAndSettle();

    expect(git.remoteDeletes, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Delete on Remote'));
    await tester.pumpAndSettle();

    expect(git.remoteDeletes, [('origin', 'feature')]);
  });

  testWidgets('the merge menu offers fast-forward only', (tester) async {
    final git = await _pump(tester);

    await tester.tap(find.byType(MacosPulldownButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge (fast-forward only)'));
    await tester.pumpAndSettle();
    // Through the confirm dialog the merge flow shows.
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();

    expect(git.merges, [MergeMode.ffOnly]);
  });
}
