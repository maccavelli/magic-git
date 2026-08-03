// Phase-1 Forge right-click menus: secondary-tapping a PR/MR row opens a
// context menu of the actions the service layer already supports (open in
// browser / copy / check out / approve / merge), and choosing a merge variant
// runs it through the same confirm dialog the detail-pane button does.

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
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/github/github_panel.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';

const _repo = '/repo';

class _MergeCapturingGh extends GhService {
  _MergeCapturingGh() : super(SSHCommandExecutor(SSHClientManager()));
  final merges = <(int, String)>[];

  @override
  Future<void> mergePullRequest(
    String repoPath,
    int number, {
    String method = 'merge',
    bool deleteBranch = false,
    String? matchHeadCommit,
    bool auto = false,
    bool disableAuto = false,
    bool admin = false,
    String? subject,
    String? body,
  }) async {
    merges.add((number, method));
  }

  @override
  Future<PullRequest> pullRequestDetail(String repoPath, int number) async =>
      _readyPr;
}

class _MergeCapturingGlab extends GlabService {
  _MergeCapturingGlab() : super(SSHCommandExecutor(SSHClientManager()));
  final merges = <(int, bool)>[];

  @override
  Future<void> mergeMergeRequest(
    String repoPath,
    int iid, {
    bool squash = false,
    bool removeSourceBranch = false,
    String? sha,
    String? squashMessage,
    String? mergeCommitMessage,
  }) async {
    merges.add((iid, squash));
  }

  @override
  Future<MergeRequest> mergeRequestDetail(String repoPath, int iid) async =>
      _readyMr;
}

/// Captures the Phase-2 GitHub write actions.
class _Phase2Gh extends GhService {
  _Phase2Gh() : super(SSHCommandExecutor(SSHClientManager()));
  final merges = <(int, String, bool)>[]; // number, method, deleteBranch
  final closed = <int>[];
  final draftSet = <(int, bool)>[]; // number, draft
  final comments = <(int, String)>[];

  @override
  Future<void> mergePullRequest(
    String repoPath,
    int number, {
    String method = 'merge',
    bool deleteBranch = false,
    String? matchHeadCommit,
    bool auto = false,
    bool disableAuto = false,
    bool admin = false,
    String? subject,
    String? body,
  }) async {
    merges.add((number, method, deleteBranch));
  }

  @override
  Future<PullRequest> pullRequestDetail(String repoPath, int number) async =>
      _readyPr;

  @override
  Future<void> closePullRequest(String repoPath, int number) async {
    closed.add(number);
  }

  @override
  Future<void> setPullRequestDraft(
    String repoPath,
    int number, {
    required bool draft,
  }) async {
    draftSet.add((number, draft));
  }

  @override
  Future<void> commentOnPullRequest(
    String repoPath,
    int number,
    String body,
  ) async {
    comments.add((number, body));
  }
}

/// Captures the Phase-2 GitLab write actions.
class _Phase2Glab extends GlabService {
  _Phase2Glab() : super(SSHCommandExecutor(SSHClientManager()));
  final closed = <int>[];
  final comments = <(int, String)>[];

  @override
  Future<void> closeMergeRequest(String repoPath, int iid) async {
    closed.add(iid);
  }

  @override
  Future<void> commentOnMergeRequest(
    String repoPath,
    int iid,
    String body,
  ) async {
    comments.add((iid, body));
  }
}

/// The panels open in Inbox mode by default; these tests exercise the Browse
/// sections, so pin them to Browse.
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

const _readyPr = PullRequest(
  number: 7,
  title: 'Add the parser',
  state: 'open',
  merged: false,
  draft: false,
  authorLogin: 'alice',
  headRefName: 'feat',
  baseRefName: 'main',
  url: 'https://github.com/o/r/pull/7',
  headOid: 'aabbccddeeff00112233445566778899aabbccdd',
  mergeable: GhMergeable.mergeable,
  mergeStateStatus: 'CLEAN',
  reviewDecision: 'APPROVED',
);

final _prs = [_readyPr];

const _readyMr = MergeRequest(
  iid: 7,
  title: 'Add the parser',
  state: 'opened',
  authorUsername: 'alice',
  sourceBranch: 'feat',
  targetBranch: 'main',
  webUrl: 'https://gitlab.com/o/r/-/merge_requests/7',
  draft: false,
  sha: 'abcdef0123456789abcdef0123456789abcdef01',
  detailedMergeStatus: 'mergeable',
);

final _mrs = [_readyMr];

Future<void> _pumpGithub(WidgetTester tester, {GhService? gh}) async {
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      if (gh != null) ghServiceProvider.overrideWithValue(gh),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      pullRequestsProvider(_repo).overrideWith((ref) async => _prs),
      pullRequestDetailProvider(
        (_repo, 7),
      ).overrideWith((ref) async => _readyPr),
      workflowRunsProvider(
        _repo,
      ).overrideWith((ref) async => const <WorkflowRun>[]),
      projectIssuesProvider(_repo).overrideWith((ref) async => const []),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
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
          child: GitHubPanel(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpGitlab(WidgetTester tester, {GlabService? glab}) async {
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      if (glab != null) glabServiceProvider.overrideWithValue(glab),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
      mergeRequestDetailProvider(
        (_repo, 7),
      ).overrideWith((ref) async => _readyMr),
      pipelinesProvider(_repo).overrideWith((ref) async => const <Pipeline>[]),
      projectIssuesProvider(_repo).overrideWith((ref) async => const []),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
      projectDashboardProvider(
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
          child: GitLabPanel(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('right-clicking a PR row opens its action menu', (tester) async {
    await _pumpGithub(tester);

    // Nothing selected yet — no detail pane, so the menu is the only surface
    // carrying these labels.
    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.text('Copy #7'), findsOneWidget);
    expect(find.text('Check out branch'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    expect(find.text('Squash and merge'), findsOneWidget);
    expect(find.text('Rebase and merge'), findsOneWidget);
  });

  testWidgets("the PR menu's squash-merge runs through the confirm dialog", (
    tester,
  ) async {
    final gh = _MergeCapturingGh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Squash and merge'));
    await tester.pumpAndSettle();

    expect(gh.merges, isEmpty, reason: 'nothing before the confirm');
    // The confirm button carries the method's verb.
    await tester.tap(find.text('Squash-merge'));
    await tester.pumpAndSettle();

    expect(gh.merges, [(7, 'squash')]);
  });

  testWidgets('right-clicking an MR row opens its menu and merges', (
    tester,
  ) async {
    final glab = _MergeCapturingGlab();
    await _pumpGitlab(tester, glab: glab);

    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Copy !7'), findsOneWidget);
    expect(find.text('Check out branch'), findsOneWidget);
    // GitLab exposes plain merge + squash (no per-merge rebase).
    expect(find.text('Rebase and merge'), findsNothing);

    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(glab.merges, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Merge')); // the confirm button
    await tester.pumpAndSettle();

    expect(glab.merges, [(7, false)]);
  });

  testWidgets('the merge dialog offers delete-branch as the second choice', (
    tester,
  ) async {
    final gh = _Phase2Gh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    // The secondary choice merges and deletes the head branch.
    await tester.tap(find.text('Merge & delete branch'));
    await tester.pumpAndSettle();

    expect(gh.merges, [(7, 'merge', true)]);
  });

  testWidgets('closing a PR from the menu confirms, then closes', (
    tester,
  ) async {
    final gh = _Phase2Gh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(gh.closed, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Close')); // the confirm button
    await tester.pumpAndSettle();

    expect(gh.closed, [7]);
  });

  testWidgets('converting a PR to draft needs no confirm', (tester) async {
    final gh = _Phase2Gh();
    await _pumpGithub(tester, gh: gh);

    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    // The open, non-draft PR offers "Convert to draft" (no confirm dialog).
    await tester.tap(find.text('Convert to draft'));
    await tester.pumpAndSettle();

    expect(gh.draftSet, [(7, true)]);
  });

  testWidgets('commenting on an MR prompts for a body, then posts it', (
    tester,
  ) async {
    final glab = _Phase2Glab();
    await _pumpGitlab(tester, glab: glab);

    await tester.tap(find.text('Add the parser'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comment…'));
    await tester.pumpAndSettle();

    // The prompt sheet's field is the last MacosTextField (the list filter is
    // the first).
    await tester.enterText(find.byType(MacosTextField).last, 'Looks good');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comment')); // the sheet's confirm button
    await tester.pumpAndSettle();

    expect(glab.comments, [(7, 'Looks good')]);
  });
}
