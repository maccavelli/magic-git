// MADR 0051 Phase 3: one fixture per BranchSyncState value, asserting the
// navigator row's badge and the detail pane's callout each show the label or
// message that state's UI contract promises.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';

/// The current branch, present in every fixture so the panel always has a
/// HEAD row (required for the view to render normally) without itself being
/// the branch under test. Given its own up-to-date upstream so it never
/// triggers any of the sync-state badges/callouts the tests below assert on.
const _head = GitRef(
  name: 'refs/heads/main',
  oid: 'head1',
  isHead: true,
  subject: 's',
  upstream: 'origin/main',
);

class _FakeGit extends GitService {
  _FakeGit({this.commonAncestor = true})
    : super(SSHCommandExecutor(SSHClientManager()));

  /// What [haveCommonAncestor] resolves to — the async half of the
  /// diverged/unrelated-histories distinction.
  final bool commonAncestor;

  @override
  Future<bool> haveCommonAncestor(String repoPath, String a, String b) async {
    return commonAncestor;
  }
}

Future<void> _pump(
  WidgetTester tester,
  List<GitRef> refs, {
  _FakeGit? git,
}) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git ?? _FakeGit()),
      refsProvider(_repo).overrideWith((ref) async => refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
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
}

void main() {
  testWidgets('noUpstream: navigator badges "Not published", detail pane '
      'explains and points to Publish', (tester) async {
    const branch = GitRef(
      name: 'refs/heads/no-upstream',
      oid: 'a1',
      isHead: false,
      subject: 's',
    );
    await _pump(tester, const [_head, branch]);

    expect(find.text('Not published'), findsOneWidget);

    await tester.tap(find.text('no-upstream'));
    await tester.pumpAndSettle();
    expect(find.textContaining("hasn't been published"), findsOneWidget);
  });

  testWidgets('staleTracking: navigator keeps "gone", detail pane explains '
      'the upstream is gone', (tester) async {
    const branch = GitRef(
      name: 'refs/heads/stale-track',
      oid: 'a2',
      isHead: false,
      subject: 's',
      upstream: 'origin/stale-track',
      upstreamGone: true,
    );
    await _pump(tester, const [_head, branch]);

    expect(find.text('gone'), findsOneWidget);

    await tester.tap(find.text('stale-track'));
    await tester.pumpAndSettle();
    expect(find.textContaining('upstream is gone'), findsOneWidget);
  });

  testWidgets('upToDate: no divergence badge, no callout', (tester) async {
    const branch = GitRef(
      name: 'refs/heads/synced',
      oid: 'a3',
      isHead: false,
      subject: 's',
      upstream: 'origin/synced',
    );
    await _pump(tester, const [_head, branch]);

    expect(find.text('Diverged'), findsNothing);
    expect(find.text('Unrelated histories'), findsNothing);
    expect(find.text('Not published'), findsNothing);

    await tester.tap(find.text('synced'));
    await tester.pumpAndSettle();
    expect(find.textContaining('diverged'), findsNothing);
    expect(find.textContaining('common history'), findsNothing);
  });

  testWidgets('aheadOnly: existing ↑n badge and push callout, unchanged by '
      'BranchSyncState', (tester) async {
    const branch = GitRef(
      name: 'refs/heads/ahead-only',
      oid: 'a4',
      isHead: false,
      subject: 's',
      upstream: 'origin/ahead-only',
      ahead: 3,
    );
    await _pump(tester, const [_head, branch]);

    expect(find.text('↑3'), findsOneWidget);
    expect(find.text('Diverged'), findsNothing);

    await tester.tap(find.text('ahead-only'));
    await tester.pumpAndSettle();
    expect(find.textContaining('or open a pull request'), findsOneWidget);
  });

  testWidgets('behindOnly: existing ↓n badge, no callout', (tester) async {
    const branch = GitRef(
      name: 'refs/heads/behind-only',
      oid: 'a5',
      isHead: false,
      subject: 's',
      upstream: 'origin/behind-only',
      behind: 2,
    );
    await _pump(tester, const [_head, branch]);

    expect(find.text('↓2'), findsOneWidget);
    expect(find.text('Diverged'), findsNothing);

    await tester.tap(find.text('behind-only'));
    await tester.pumpAndSettle();
    expect(find.textContaining('diverged'), findsNothing);
  });

  testWidgets('diverged: navigator badges "Diverged" alongside the counts, '
      'detail pane offers to reconcile', (tester) async {
    const branch = GitRef(
      name: 'refs/heads/diverged',
      oid: 'a6',
      isHead: false,
      subject: 's',
      upstream: 'origin/diverged',
      ahead: 2,
      behind: 1,
    );
    const remote = GitRef(
      name: 'refs/remotes/origin/diverged',
      oid: 'r6',
      isHead: false,
      subject: 's',
    );
    await _pump(tester, const [
      _head,
      branch,
      remote,
    ], git: _FakeGit(commonAncestor: true));

    expect(find.text('Diverged'), findsOneWidget);
    expect(find.text('↑2 ↓1'), findsOneWidget);

    await tester.tap(find.text('diverged'));
    await tester.pumpAndSettle();
    expect(find.textContaining('have diverged'), findsOneWidget);
    expect(find.textContaining('Reconcile'), findsOneWidget);
  });

  testWidgets(
    'unrelatedHistories: navigator still shows the coarse "Diverged" badge '
    '(no per-row git call), detail pane resolves and says so',
    (tester) async {
      const branch = GitRef(
        name: 'refs/heads/unrelated',
        oid: 'a7',
        isHead: false,
        subject: 's',
        upstream: 'origin/unrelated',
        ahead: 2,
        behind: 1,
      );
      const remote = GitRef(
        name: 'refs/remotes/origin/unrelated',
        oid: 'r7',
        isHead: false,
        subject: 's',
      );
      await _pump(tester, const [
        _head,
        branch,
        remote,
      ], git: _FakeGit(commonAncestor: false));

      // The navigator row only ever uses the synchronous coarse
      // classification (MADR 0051: a Browse row must not cost a
      // `git merge-base` per visible diverged branch), so it cannot
      // distinguish unrelated histories from an ordinary divergence — it
      // shows "Diverged" either way, with the counts.
      expect(find.text('Diverged'), findsOneWidget);
      expect(find.text('↑2 ↓1'), findsOneWidget);
      expect(find.text('Unrelated histories'), findsNothing);

      // The detail pane, scoped to the one selected branch, resolves the
      // real distinction via the async provider.
      await tester.tap(find.text('unrelated'));
      await tester.pumpAndSettle();
      expect(find.textContaining('share no common history'), findsOneWidget);
    },
  );
}
