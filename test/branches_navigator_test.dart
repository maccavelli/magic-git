// Phase-1 structure of the redesigned Branches tab: the master–detail split,
// selecting a row drives the detail pane's actions, the flat-default list with
// a group-by-folder toggle, and the stale-branch collapse.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/adaptive_workspace_layout.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';

const _repo = '/repo';

class _NoopGit extends GitService {
  _NoopGit() : super(SSHCommandExecutor(SSHClientManager()));
}

int _daysAgo(int days) =>
    DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch ~/
    1000;

List<GitRef> _refs() => [
  const GitRef(name: 'refs/heads/main', oid: 'a', isHead: true, subject: 's'),
  const GitRef(
    name: 'refs/heads/feature/login',
    oid: 'b',
    isHead: false,
    subject: 's',
  ),
  const GitRef(
    name: 'refs/heads/feature/signup',
    oid: 'c',
    isHead: false,
    subject: 's',
  ),
  const GitRef(
    name: 'refs/heads/fix/crash',
    oid: 'd',
    isHead: false,
    subject: 's',
  ),
];

/// main + a fresh branch + one branch untouched for ~200 days (stale).
List<GitRef> _staleRefs() => [
  const GitRef(name: 'refs/heads/main', oid: 'a', isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/fresh',
    oid: 'b',
    isHead: false,
    subject: 's',
    creatorDate: _daysAgo(3),
  ),
  GitRef(
    name: 'refs/heads/ancient',
    oid: 'c',
    isHead: false,
    subject: 's',
    creatorDate: _daysAgo(200),
  ),
];

Future<void> _pump(WidgetTester tester, {List<GitRef>? refs}) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_NoopGit()),
      refsProvider(_repo).overrideWith((ref) async => refs ?? _refs()),
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
  testWidgets('renders as a master–detail split with the review dashboard', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(RepositoryWorkspaceScaffold), findsOneWidget);
    expect(find.byType(AdaptiveWorkspaceLayout), findsOneWidget);
    // The empty state is the review dashboard: a title + stat chips.
    expect(find.text('Branches'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(find.textContaining('Select a branch or tag'), findsOneWidget);
  });

  testWidgets('selecting a branch fills the detail pane with its actions', (
    tester,
  ) async {
    await _pump(tester);

    // Nothing selected → no per-branch actions yet.
    expect(find.widgetWithText(InlineActionButton, 'Rename…'), findsNothing);

    await tester.tap(find.text('fix/crash'));
    await tester.pumpAndSettle();

    // Primary action is Check out; Merge/Rename live under More.
    expect(
      find.widgetWithText(InlineActionButton, 'Check out'),
      findsOneWidget,
    );
    expect(find.text('More'), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Merge into current'), findsOneWidget);
    expect(find.text('Rename…'), findsOneWidget);
  });

  testWidgets('flat by default; the toggle groups branches into folders', (
    tester,
  ) async {
    await _pump(tester);

    // Flat: the full slash name is one row, no folder rows.
    expect(find.text('feature/login'), findsOneWidget);
    expect(find.text('feature/'), findsNothing);

    // Toggle grouping (the flat-list icon in the toolbar).
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.list_bullet,
      ),
    );
    await tester.pumpAndSettle();

    // Grouped: a feature/ folder with leaves shown by their last segment.
    expect(find.text('feature/'), findsOneWidget);
    expect(find.text('fix/'), findsOneWidget);
    expect(find.text('login'), findsOneWidget);
    expect(find.text('feature/login'), findsNothing);

    // The extracted navigator must receive folder-prefix state, not the
    // unrelated global section-collapse keys.
    await tester.tap(find.text('feature/'));
    await tester.pumpAndSettle();
    expect(find.text('login'), findsNothing);
    expect(find.text('signup'), findsNothing);

    await tester.tap(find.text('feature/'));
    await tester.pumpAndSettle();
    expect(find.text('login'), findsOneWidget);
  });

  testWidgets('stale branches collapse behind a summary row that expands', (
    tester,
  ) async {
    await _pump(tester, refs: _staleRefs());

    // The stale branch is hidden; a summary toggle row stands in. (The
    // dashboard also mentions "stale", so target the toggle by its exact text.)
    expect(find.text('ancient'), findsNothing);
    expect(find.text('fresh'), findsOneWidget);
    expect(find.text('1 stale (no commit in 3 months)'), findsOneWidget);

    await tester.tap(find.text('1 stale (no commit in 3 months)'));
    await tester.pumpAndSettle();

    expect(find.text('ancient'), findsOneWidget);
  });
}
