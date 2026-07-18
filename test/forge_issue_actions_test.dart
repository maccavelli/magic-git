// Phase-3 issue management: the issue row's right-click menu and the detail
// action bar (issues were view-only before). Covers the branch-name slug, the
// menu contents + a state mutation, and the "start work → branch" split
// (gh issue develop on GitHub, a local branch on GitLab).

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
import 'package:remote_magic_git/features/forge/issue_actions.dart';
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

  @override
  Future<void> closeIssue(String repoPath, int number) async {
    closed.add(number);
  }

  @override
  Future<void> developIssueBranch(String repoPath, int number) async {
    developed.add(number);
  }
}

class _NoopGlab extends GlabService {
  _NoopGlab() : super(SSHCommandExecutor(SSHClientManager()));
}

class _CapturingGit extends GitService {
  _CapturingGit() : super(SSHCommandExecutor(SSHClientManager()));
  final branches = <String>[];

  @override
  Future<void> createBranch(
    String repoPath,
    String name, {
    bool checkout = true,
  }) async {
    branches.add(name);
  }
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

GitStatus _clean() =>
    GitStatus(branch: const GitBranchInfo(), files: const []);

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
      issueDetailProvider(
        (_repo, 8),
      ).overrideWith((ref) async => _issue),
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

Future<void> _pumpGitlab(
  WidgetTester tester, {
  required GitService git,
}) async {
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      glabServiceProvider.overrideWithValue(_NoopGlab()),
      gitServiceProvider.overrideWithValue(git),
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
  group('issueBranchName', () {
    test('slugifies the title and prefixes the iid', () {
      expect(issueBranchName(8, 'Fix the crash'), '8-fix-the-crash');
    });
    test('collapses punctuation and trims dashes', () {
      expect(
        issueBranchName(12, '  Add: OAuth (v2)!  '),
        '12-add-oauth-v2',
      );
    });
    test('falls back to just the iid when the title has no word chars', () {
      expect(issueBranchName(5, '!!!'), '5');
    });
  });

  testWidgets('right-clicking an issue row opens the management menu', (
    tester,
  ) async {
    await _pumpGithub(tester, gh: _IssueGh());

    await tester.tap(find.text('Fix the crash'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Start work → create branch'), findsOneWidget);
    expect(find.text('Comment…'), findsOneWidget);
    expect(find.text('Assign to me'), findsOneWidget); // GitHub only
    expect(find.text('Edit title…'), findsOneWidget);
    expect(find.text('Copy #8'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
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

    // Select the issue → its detail pane, then start work (clean tree, so the
    // dirty-switch guard runs the checkout directly).
    await tester.tap(find.text('Fix the crash'));
    await tester.pumpAndSettle();
    expect(find.text('Start work'), findsOneWidget);

    await tester.tap(find.text('Start work'));
    await tester.pumpAndSettle();

    expect(gh.developed, [8]);
  });

  testWidgets(
    'GitLab "Start work" creates a local <iid>-slug branch after confirm',
    (tester) async {
      final git = _CapturingGit();
      await _pumpGitlab(tester, git: git);

      await tester.tap(find.text('Fix the crash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start work'));
      await tester.pumpAndSettle();

      // GitLab has no issue→branch command, so it confirms the local-branch
      // fallback first.
      expect(git.branches, isEmpty, reason: 'nothing before the confirm');
      await tester.tap(find.text('Create & check out'));
      await tester.pumpAndSettle();

      expect(git.branches, ['8-fix-the-crash']);
    },
  );
}
