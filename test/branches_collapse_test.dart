// Canonical per-section minimize/expand on the Branches tab: each list header
// (Pinned / Local Branches / Remote Branches / Tags) has a disclosure chevron
// that hides its rows in place, backed by the shared collapsedSectionsProvider
// it shares with the Forge tab. A live filter force-expands every section.

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
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
}

/// HEAD plus one extra local branch, one remote-tracking branch, and one tag —
/// one visible row per section so a section's presence is unambiguous.
List<GitRef> _refs() => [
  const GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  const GitRef(
    name: 'refs/heads/feature-x',
    oid: 'bbb',
    isHead: false,
    subject: 's',
  ),
  const GitRef(
    name: 'refs/remotes/origin/dev',
    oid: 'ccc',
    isHead: false,
    subject: 's',
  ),
  const GitRef(
    name: 'refs/tags/v1',
    oid: 'ddd',
    isHead: false,
    subject: 's',
    creatorDate: 1000,
  ),
];

Future<void> _pump(WidgetTester tester, {TextEditingController? filter}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit()),
      refsProvider(_repo).overrideWith((ref) async => _refs()),
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
  testWidgets('minimizing Local Branches hides its rows, expanding restores', (
    tester,
  ) async {
    await _pump(tester);

    // Both local branches are on screen under an expanded header.
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feature-x'), findsOneWidget);

    // Click the header to collapse: the branch rows vanish, the header stays.
    await tester.tap(find.text('Local Branches (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Local Branches (2)'), findsOneWidget);
    expect(find.text('main'), findsNothing);
    expect(find.text('feature-x'), findsNothing);

    // Other sections are untouched.
    expect(find.text('origin/dev'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);

    // Click again to expand.
    await tester.tap(find.text('Local Branches (2)'));
    await tester.pumpAndSettle();
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feature-x'), findsOneWidget);
  });

  testWidgets('each section collapses independently', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Remote Branches (1)'));
    await tester.pumpAndSettle();
    expect(find.text('origin/dev'), findsNothing);
    // Locals and tags remain.
    expect(find.text('feature-x'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);

    await tester.tap(find.text('Tags (1)'));
    await tester.pumpAndSettle();
    expect(find.text('v1'), findsNothing);
    expect(find.text('feature-x'), findsOneWidget);
  });

  testWidgets('a filter force-expands a collapsed section', (tester) async {
    await _pump(tester);

    // Collapse Local Branches.
    await tester.tap(find.text('Local Branches (2)'));
    await tester.pumpAndSettle();
    expect(find.text('feature-x'), findsNothing);

    // Typing a filter is a request to see every match — the collapsed section
    // re-opens to show the hit.
    await tester.enterText(find.byType(MacosTextField).first, 'feature');
    await tester.pumpAndSettle();
    expect(find.text('feature-x'), findsOneWidget);
  });
}
