// MADR 0051 Phase 6: after Fetch & Prune, branches whose upstream was just
// deleted are offered for cleanup in one confirmation.

import 'package:flutter/cupertino.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';

const _repo = '/repo';
const _ok = SSHCommandResult(exitCode: 0, stdout: '', stderr: '');

GitRef _branch(
  String name, {
  bool gone = false,
  bool head = false,
  String? worktreePath,
}) => GitRef(
  name: 'refs/heads/$name',
  oid: 'oid-$name',
  isHead: head,
  subject: 's',
  upstream: 'origin/$name',
  upstreamGone: gone,
  worktreePath: worktreePath,
);

/// Before the fetch: `old` is already gone; `a`, `b`, the current branch and
/// a branch checked out in another worktree all still track live upstreams.
final _before = [
  _branch('main', head: true),
  _branch('a'),
  _branch('b'),
  _branch('old', gone: true),
  _branch('wt', worktreePath: '/elsewhere/wt'),
];

/// After it: every one of them is gone. Only `a` and `b` are both newly gone
/// and deletable — git refuses the current branch and a branch checked out
/// elsewhere, and `old` was already gone before this fetch.
final _after = [
  _branch('main', head: true, gone: true),
  _branch('a', gone: true),
  _branch('b', gone: true),
  _branch('old', gone: true),
  _branch('wt', gone: true, worktreePath: '/elsewhere/wt'),
];

class _FakeGit extends GitService {
  _FakeGit({required this.afterFetch, this.unmerged = const {}})
    : super(SSHCommandExecutor(SSHClientManager()));

  /// The ref list the fetch reveals.
  final List<GitRef> afterFetch;

  /// Branches `git branch -d` refuses as not fully merged.
  final Set<String> unmerged;

  List<GitRef> current = _before;
  final List<(String, bool)> deletes = [];

  @override
  Future<SSHCommandResult> fetch(
    String repoPath, {
    bool background = false,
    FetchScope scope = FetchScope.allRemotes,
    CommandOutputCallback? onOutput,
    OperationId? operationId,
    String? upstreamRemote,
  }) async {
    current = afterFetch;
    return _ok;
  }

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    if (!force && unmerged.contains(name)) {
      throw GitException(
        'git branch -d',
        SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: "error: the branch '$name' is not fully merged",
        ),
      );
    }
    deletes.add((name, force));
  }
}

Future<void> _pumpAndFetch(WidgetTester tester, _FakeGit git) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => git.current),
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

  await tester.tap(
    find.byWidgetPredicate(
      (w) =>
          w is ToolIconButton &&
          w.tooltip == 'Fetch all remotes and prune deleted branches',
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('branches newly gone after the fetch are offered — only the '
      'deletable ones', (tester) async {
    final git = _FakeGit(afterFetch: _after);
    await _pumpAndFetch(tester, git);

    expect(find.text('Clean up stale branches?'), findsOneWidget);
    expect(find.textContaining('2 branches no longer exist'), findsOneWidget);
    expect(find.textContaining('"a", "b"'), findsOneWidget);
    for (final excluded in ['"main"', '"old"', '"wt"']) {
      expect(
        find.textContaining(excluded),
        findsNothing,
        reason: '$excluded is not newly gone, or git would refuse it',
      );
    }
    expect(git.deletes, isEmpty, reason: 'nothing before the confirm');

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(git.deletes, [('a', false), ('b', false)]);
  });

  testWidgets('cancelling deletes nothing', (tester) async {
    final git = _FakeGit(afterFetch: _after);
    await _pumpAndFetch(tester, git);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(git.deletes, isEmpty);
  });

  testWidgets('a fetch that reveals nothing newly gone offers nothing', (
    tester,
  ) async {
    final git = _FakeGit(afterFetch: _before);
    await _pumpAndFetch(tester, git);

    expect(find.text('Clean up stale branches?'), findsNothing);
    expect(git.deletes, isEmpty);
  });

  testWidgets('an unmerged branch gets one force-delete follow-up, not an '
      'error', (tester) async {
    final git = _FakeGit(afterFetch: _after, unmerged: {'b'});
    await _pumpAndFetch(tester, git);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(git.deletes, [('a', false)], reason: '"a" merged, deleted plainly');
    expect(find.text('Branch not fully merged'), findsOneWidget);
    expect(find.textContaining('"b" has commits not merged'), findsOneWidget);

    await tester.tap(find.text('Force Delete'));
    await tester.pumpAndSettle();

    expect(git.deletes, [('a', false), ('b', true)]);
  });

  testWidgets('declining the force-delete keeps the unmerged branch', (
    tester,
  ) async {
    final git = _FakeGit(afterFetch: _after, unmerged: {'b'});
    await _pumpAndFetch(tester, git);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(git.deletes, [('a', false)]);
  });
}
