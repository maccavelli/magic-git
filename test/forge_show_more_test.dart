// The Forge panels' CI lists (GitLab pipelines / GitHub workflow runs):
// collapsed to the 10 newest with a "Show more" row that flips the scope
// notifier, re-fetching the SAME provider with full history while the current
// rows stay on screen (skipLoadingOnReload) behind a busy row.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/github/github_panel.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';

const _repo = '/repo';

// A remote-tracking ref so the panels' "no remote → notice" gate lets the
// CI lists render.
final _remoteRefs = [
  const GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'deadbeef',
    isHead: false,
    subject: '',
  ),
];

List<Pipeline> _pipelines(int count) => [
  for (var i = 0; i < count; i++)
    Pipeline(id: i, status: 'success', ref: 'ref$i', sha: 'aaaaaaaa', webUrl: ''),
];

List<WorkflowRun> _runs(int count) => [
  for (var i = 0; i < count; i++)
    WorkflowRun(
      id: i,
      status: 'completed',
      conclusion: 'success',
      headBranch: 'branch$i',
      headSha: 'aaaaaaaa$i',
      workflowName: 'wf$i',
      url: '',
    ),
];

Future<void> _pumpPanel(
  WidgetTester tester,
  Widget panel,
  ProviderContainer container,
) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(debugShowCheckedModeBanner: false, home: panel),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'GitLab pipelines collapse to 10; Show more re-fetches full history in '
    'place, keeping current rows up behind a busy row',
    (tester) async {
      final fullFetch = Completer<List<Pipeline>>();
      final container = ProviderContainer(overrides: [
        refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
        mergeRequestsProvider(_repo).overrideWith((ref) async => const []),
        // Mirrors the real provider's shape: watches the scope notifier so
        // the Show-more tap re-fetches this same instance.
        pipelinesProvider(_repo).overrideWith((ref) {
          final full = ref.watch(pipelinesScopeProvider(_repo));
          return full ? fullFetch.future : Future.value(_pipelines(30));
        }),
      ]);
      await _pumpPanel(tester, const GitLabPanel(repoPath: _repo), container);

      // 30 fetched, 10 shown.
      expect(find.text('ref0  ·  aaaaaaaa'), findsOneWidget);
      expect(find.text('ref9  ·  aaaaaaaa'), findsOneWidget);
      expect(find.text('ref10  ·  aaaaaaaa'), findsNothing);
      expect(find.text('Show all pipelines'), findsOneWidget);

      // Expanding: the current rows must stay while the deep fetch runs.
      await tester.tap(find.text('Show all pipelines'));
      await tester.pump();
      expect(find.text('ref0  ·  aaaaaaaa'), findsOneWidget);
      expect(find.text('Loading pipeline history…'), findsOneWidget);

      fullFetch.complete(_pipelines(45));
      await tester.pumpAndSettle();
      expect(find.text('ref44  ·  aaaaaaaa'), findsOneWidget);
      expect(find.text('Show all pipelines'), findsNothing);
      expect(find.text('Loading pipeline history…'), findsNothing);
    },
  );

  testWidgets(
    'GitHub workflow runs collapse to 10 with the same Show more expansion',
    (tester) async {
      final container = ProviderContainer(overrides: [
        refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
        pullRequestsProvider(_repo).overrideWith((ref) async => const []),
        workflowRunsProvider(_repo).overrideWith((ref) async {
          final full = ref.watch(workflowRunsScopeProvider(_repo));
          return _runs(full ? 45 : 30);
        }),
      ]);
      await _pumpPanel(tester, const GitHubPanel(repoPath: _repo), container);

      expect(find.text('wf9'), findsOneWidget);
      expect(find.text('wf10'), findsNothing);
      expect(find.text('Show all workflow runs'), findsOneWidget);

      await tester.tap(find.text('Show all workflow runs'));
      await tester.pumpAndSettle();

      expect(find.text('wf44'), findsOneWidget);
      expect(find.text('Show all workflow runs'), findsNothing);
    },
  );

  testWidgets(
    'a short CI list renders whole with no Show more row',
    (tester) async {
      final container = ProviderContainer(overrides: [
        refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
        mergeRequestsProvider(_repo).overrideWith((ref) async => const []),
        pipelinesProvider(_repo).overrideWith((ref) async => _pipelines(3)),
      ]);
      await _pumpPanel(tester, const GitLabPanel(repoPath: _repo), container);

      expect(find.text('ref2  ·  aaaaaaaa'), findsOneWidget);
      expect(find.text('Show all pipelines'), findsNothing);
    },
  );
}
