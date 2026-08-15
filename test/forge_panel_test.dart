// Verifies the Forge tab dispatcher routes to the right panel/notice based on
// the detected forge, so a GitHub repo gets the GitHub panel, a GitLab repo the
// (unchanged) GitLab panel, and unrecognized/remoteless repos a clear notice.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';
import 'package:remote_magic_git/features/forge/forge_panel.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';

const _repo = '/repo';

final _remoteRefs = [
  const GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'deadbeef',
    isHead: false,
    subject: '',
  ),
];

/// These tests assert on the Browse sections' headers; the panels open in
/// Inbox mode by default, so pin them to Browse.
class _BrowseMode extends ForgeInboxMode {
  @override
  bool build() => false;
}

Future<void> _pumpForge(WidgetTester tester, Forge forge) async {
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      forgeProvider(_repo).overrideWith((ref) async => forge),
      // Keep the underlying forge panels from hitting a real executor.
      // The forge chrome now names the real HEAD in the Branch slot (0009
      // M6), so status must be stubbed like every other provider here.
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(head: 'main'),
          files: const [],
        ),
      ),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      pullRequestsProvider(_repo).overrideWith((ref) async => const []),
      workflowRunsProvider(_repo).overrideWith((ref) async => const []),
      mergeRequestsProvider(_repo).overrideWith((ref) async => const []),
      pipelinesProvider(_repo).overrideWith((ref) async => const []),
      // The unified Forge panels also render the project sections — settle
      // their providers so no section is left spinning.
      projectIssuesProvider(_repo).overrideWith((ref) async => const []),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
      projectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
      githubProjectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
      originRemoteUrlProvider(_repo).overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 1100,
          height: 720,
          child: ForgePanel(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('github → the GitHub panel', (tester) async {
    await _pumpForge(tester, Forge.github);
    expect(find.byType(RepositoryWorkspaceScaffold), findsOneWidget);
    expect(find.text('New Pull Request'), findsOneWidget);
    expect(find.text('Pull Requests'), findsOneWidget);
    expect(find.text('Merge Requests'), findsNothing);
  });

  testWidgets('gitlab → the (unchanged) GitLab panel', (tester) async {
    await _pumpForge(tester, Forge.gitlab);
    expect(find.byType(RepositoryWorkspaceScaffold), findsOneWidget);
    expect(find.text('New Merge Request'), findsOneWidget);
    expect(find.text('Merge Requests'), findsOneWidget);
    expect(find.text('Pull Requests'), findsNothing);
  });

  testWidgets('none → the no-remote notice', (tester) async {
    await _pumpForge(tester, Forge.none);
    expect(find.text('No remote detected'), findsOneWidget);
  });

  testWidgets('unknown → the unsupported-forge notice', (tester) async {
    await _pumpForge(tester, Forge.unknown);
    expect(find.text('Unsupported forge'), findsOneWidget);
  });
}
