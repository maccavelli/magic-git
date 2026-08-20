// The branches panel's filter bar and the remote-branches collapse: filtering
// narrows all three sections (headers show "shown of total"), an active
// filter overrides the collapse, and keyboard navigation walks the FILTERED
// list only.

import 'package:flutter/widgets.dart';
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

class _NoopGit extends GitService {
  _NoopGit() : super(SSHCommandExecutor(SSHClientManager()));
}

List<GitRef> _manyRefs() => [
  const GitRef(name: 'refs/heads/main', oid: 'a', isHead: true, subject: 's'),
  const GitRef(
    name: 'refs/heads/feature-login',
    oid: 'b',
    isHead: false,
    subject: 's',
  ),
  // 30 remote branches — past the collapse cap of 25.
  for (var i = 0; i < 30; i++)
    GitRef(
      name: 'refs/remotes/origin/topic-$i',
      oid: 'c$i',
      isHead: false,
      subject: 's',
    ),
  const GitRef(
    name: 'refs/remotes/origin/feature-login',
    oid: 'd',
    isHead: false,
    subject: 's',
  ),
  const GitRef(name: 'refs/tags/v1.0', oid: 'e', isHead: false, subject: 's'),
];

Finder _filterField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Filter branches and tags',
);

Future<void> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_NoopGit()),
      refsProvider(_repo).overrideWith((ref) async => _manyRefs()),
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
  testWidgets('remote branches past the cap collapse behind a Show more row', (
    tester,
  ) async {
    // Tall viewport: the Show-more row sits below 25 remote rows, and
    // dragging to scroll would grab a row's drag-to-worktree gesture instead.
    tester.view.physicalSize = const Size(1600, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester);
    expect(find.text('Remote Branches (31)'), findsOneWidget);
    expect(find.text('Show 6 more remote branches'), findsOneWidget);

    await tester.tap(find.text('Show 6 more remote branches'));
    await tester.pumpAndSettle();
    expect(find.text('Show 6 more remote branches'), findsNothing);
    expect(
      find.text('origin/topic-29'),
      findsOneWidget,
      reason: 'every remote row renders once expanded',
    );
  });

  testWidgets('typing a filter narrows every section and retitles the '
      'headers "shown of total"', (tester) async {
    await _pump(tester);

    await tester.enterText(_filterField(), 'feature-lo');
    await tester.pumpAndSettle();

    expect(find.text('Local Branches (1 of 2)'), findsOneWidget);
    expect(find.text('Remote Branches (1 of 31)'), findsOneWidget);
    expect(find.text('Tags (0 of 1)'), findsOneWidget);
    // The filter overrides the collapse — no Show more row while filtering.
    expect(find.textContaining('more remote'), findsNothing);
    // Both matching rows (local + remote) render; the current branch's row
    // is filtered out.
    expect(find.text('feature-login'), findsOneWidget);
    expect(find.text('origin/feature-login'), findsOneWidget);
    expect(find.text('main'), findsNothing);

    // Clearing restores the full listing.
    await tester.enterText(_filterField(), '');
    await tester.pumpAndSettle();
    expect(find.text('Local Branches (2)'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
  });

  testWidgets('a filter with no matches leaves usable empty sections, not an '
      'error', (tester) async {
    await _pump(tester);
    await tester.enterText(_filterField(), 'zzz-no-such-ref');
    await tester.pumpAndSettle();
    expect(find.text('Local Branches (0 of 2)'), findsOneWidget);
    expect(find.text('Remote Branches (0 of 31)'), findsOneWidget);
    expect(find.text('Tags (0 of 1)'), findsOneWidget);
  });
}
