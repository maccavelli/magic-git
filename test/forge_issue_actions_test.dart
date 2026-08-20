// Phase-3 issue management: the issue row's right-click menu and the detail
// action bar (issues were view-only before). Covers the menu contents, a state
// mutation, the GitHub-only "start work → branch" (gh issue develop), that it
// is hidden on GitLab, and the full title+body edit via the shared form sheet.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/github/github_panel.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';

const _repo = '/repo';

const _issue = ForgeIssue(
  id: 8,
  title: 'Fix the crash',
  state: 'open',
  author: 'alice',
);

class _IssueGh extends GhService {
  _IssueGh() : super(SSHCommandExecutor(SSHClientManager()));
  final closed = <int>[];
  final developed = <int>[];
  final edited = <(int, String, String)>[]; // number, title, body

  @override
  Future<void> closeIssue(String repoPath, int number) async {
    closed.add(number);
  }

  @override
  Future<void> developIssueBranch(String repoPath, int number) async {
    developed.add(number);
  }

  @override
  Future<ForgeIssue> issueDetail(String repoPath, int number) async =>
      const ForgeIssue(
        id: 8,
        title: 'Fix the crash',
        state: 'open',
        body: 'old body',
      );

  @override
  Future<void> editIssue(
    String repoPath,
    int number, {
    String? title,
    String? body,
  }) async {
    edited.add((number, title ?? '', body ?? ''));
  }
}

class _NoopGlab extends GlabService {
  _NoopGlab() : super(SSHCommandExecutor(SSHClientManager()));
}

class _BrowseMode extends ForgeInboxMode {
  @override
  bool build() => false;
}

final _remoteRefs = [
  const GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'deadbeef',
    isHead: false,
    subject: '',
  ),
];

GitStatus _clean() => GitStatus(branch: const GitBranchInfo(), files: const []);

Future<void> _pumpGithub(WidgetTester tester, {required GhService gh}) async {
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      ghServiceProvider.overrideWithValue(gh),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      statusProvider(_repo).overrideWith((ref) async => _clean()),
      pullRequestsProvider(
        _repo,
      ).overrideWith((ref) async => const <PullRequest>[]),
      workflowRunsProvider(
        _repo,
      ).overrideWith((ref) async => const <WorkflowRun>[]),
      projectIssuesProvider(_repo).overrideWith((ref) async => const [_issue]),
      issueDetailProvider((_repo, 8)).overrideWith((ref) async => _issue),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
      githubProjectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
      originRemoteUrlProvider(
        _repo,
      ).overrideWith((ref) async => 'https://github.com/o/r.git'),
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
          height: 760,
          child: GitHubPanel(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpGitlab(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      glabServiceProvider.overrideWithValue(_NoopGlab()),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      statusProvider(_repo).overrideWith((ref) async => _clean()),
      mergeRequestsProvider(
        _repo,
      ).overrideWith((ref) async => const <MergeRequest>[]),
      pipelinesProvider(_repo).overrideWith((ref) async => const <Pipeline>[]),
      projectIssuesProvider(_repo).overrideWith((ref) async => const [_issue]),
      issueDetailProvider((_repo, 8)).overrideWith((ref) async => _issue),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
      projectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
      originRemoteUrlProvider(
        _repo,
      ).overrideWith((ref) async => 'https://gitlab.com/o/r.git'),
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
          height: 760,
          child: GitLabPanel(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('right-clicking a GitHub issue row opens the management menu', (
    tester,
  ) async {
    await _pumpGithub(tester, gh: _IssueGh());

    await tester.tap(find.text('Fix the crash'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Start work → create branch'), findsOneWidget);
    expect(find.text('Comment…'), findsOneWidget);
    expect(find.text('Assign to me'), findsOneWidget); // GitHub only
    expect(find.text('Edit…'), findsOneWidget);
    expect(find.text('Copy #8'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('the GitLab issue menu hides Start work and Assign to me', (
    tester,
  ) async {
    await _pumpGitlab(tester);

    await tester.tap(find.text('Fix the crash'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    // The forge-neutral actions are present…
    expect(find.text('Comment…'), findsOneWidget);
    expect(find.text('Edit…'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    // …but the two GitHub-only actions are not.
    expect(find.text('Start work → create branch'), findsNothing);
    expect(find.text('Assign to me'), findsNothing);
  });

  testWidgets('closing an issue from the menu confirms, then closes', (
    tester,
  ) async {
    final gh = _IssueGh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Fix the crash'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(gh.closed, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Close')); // the confirm button
    await tester.pumpAndSettle();

    expect(gh.closed, [8]);
  });

  testWidgets('the issue detail "Start work" runs gh issue develop', (
    tester,
  ) async {
    final gh = _IssueGh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Fix the crash'));
    await tester.pumpAndSettle();
    expect(find.text('Start work'), findsOneWidget);

    await tester.tap(find.text('Start work'));
    await tester.pumpAndSettle();

    expect(gh.developed, [8]);
  });

  testWidgets('editing an issue opens the title+body form and saves both', (
    tester,
  ) async {
    final gh = _IssueGh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Fix the crash'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit…'));
    await tester.pumpAndSettle();

    // The multi-field sheet: a Title field and a Description field, prefilled
    // from the fetched issue.
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);

    // The body field is the last text field (the list filter is first, then
    // title, then description). Rewrite the body, keep the title.
    await tester.enterText(find.byType(MacosTextField).last, 'a fresh body');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(gh.edited, [(8, 'Fix the crash', 'a fresh body')]);
  });
}
