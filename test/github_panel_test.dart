// Verifies the GitHub (Forge) panel's left-pane / main-panel layout: PRs and
// workflow runs list on the left; selecting one opens its detail on the right.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/github/github_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MergeCapturingGh extends GhService {
  _MergeCapturingGh() : super(SSHCommandExecutor(SSHClientManager()));
  final List<(int, String, String?)> merges = [];

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
    merges.add((number, method, matchHeadCommit));
  }

  @override
  Future<PullRequest> pullRequestDetail(String repoPath, int number) async {
    return _readyPr;
  }
}

const _repo = '/repo';

const _readyPr = PullRequest(
  number: 7,
  title: 'Add the parser',
  state: 'open',
  merged: false,
  draft: false,
  authorLogin: 'alice',
  headRefName: 'feat',
  baseRefName: 'main',
  url: '',
  headOid: 'aabbccddeeff00112233445566778899aabbccdd',
  mergeable: GhMergeable.mergeable,
  mergeStateStatus: 'CLEAN',
  reviewDecision: 'APPROVED',
);

final _prs = [_readyPr];

final _runs = [
  const WorkflowRun(
    id: 200,
    status: 'completed',
    conclusion: 'success',
    headBranch: 'main',
    headSha: 'aaaaaaa1zzz',
    workflowName: 'Build',
    url: '',
  ),
  const WorkflowRun(
    id: 201,
    status: 'completed',
    conclusion: 'failure',
    headBranch: 'feat',
    headSha: 'bbbbbbb2zzz',
    workflowName: 'Test',
    url: '',
  ),
];

final _jobs = [
  const GhJob(
    id: 900,
    name: 'build',
    status: 'completed',
    conclusion: 'success',
  ),
];

final _remoteRefs = [
  const GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'deadbeef',
    isHead: false,
    subject: '',
  ),
];

/// These tests exercise the Browse sections; the panel opens in Inbox mode
/// by default, so pin it to Browse.
class _BrowseMode extends ForgeInboxMode {
  @override
  bool build() => false;
}

Future<void> _pump(WidgetTester tester, {GhService? gh}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      if (gh != null) ghServiceProvider.overrideWithValue(gh),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      // Sibling of the refs override: the views now read CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs.
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      pullRequestsProvider(_repo).overrideWith((ref) async => _prs),
      pullRequestDetailProvider((
        _repo,
        7,
      )).overrideWith((ref) async => _readyPr),
      repoMergePolicyProvider(
        _repo,
      ).overrideWith((ref) async => const GhRepoMergePolicy()),
      workflowRunsProvider(_repo).overrideWith((ref) async => _runs),
      runJobsProvider((_repo, 200)).overrideWith((ref) => Stream.value(_jobs)),
      // The PR detail's inline Checks body mounts the head branch's latest
      // run (run 201 — branch 'feat' matches the PR's head).
      runJobsProvider((_repo, 201)).overrideWith((ref) => Stream.value(_jobs)),
      // The unified Forge panel also renders the project sections — settle
      // their providers so no section is left spinning.
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

/// Status dots / tool buttons use macos_ui's MacosIcon, which find.byIcon
/// (material Icon only) does not match.
Finder _macosIcon(IconData d) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == d);

void main() {
  testWidgets('lists PRs and workflow runs; re-run icon only when rerunnable', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Pull Requests'), findsOneWidget);
    expect(find.text('Workflow Runs'), findsOneWidget);
    expect(find.text('Add the parser'), findsOneWidget);
    expect(find.text('Build'), findsOneWidget);
    expect(find.text('Test'), findsOneWidget);

    // Exactly one re-run icon — for the single failed run (Test).
    expect(_macosIcon(CupertinoIcons.refresh_thick), findsOneWidget);

    // Nothing selected yet.
    expect(find.text('Select an item on the left'), findsOneWidget);
  });

  testWidgets('the left-pane divider drags and persists its width', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // The mock prefs store is process-static: without this reset the width
    // persisted below would leak into the OTHER tests in this file (whose
    // _pump does not reseed prefs) and shift their layout.
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await _pump(tester);

    final gesture = await tester.startGesture(
      const Offset(360.5, 300), // the divider (forgeList default width)
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_forgeList'), 380);
  });

  testWidgets('selecting a run opens its jobs in the main pane', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Build'));
    await tester.pumpAndSettle();

    expect(find.text('Select an item on the left'), findsNothing);
    expect(find.text('build'), findsOneWidget); // job row
    expect(find.text('Select a job to view its log'), findsOneWidget);
  });

  testWidgets('left-pane sections list in the canonical order', (tester) async {
    await _pump(tester);
    double y(String label) => tester.getTopLeft(find.text(label)).dy;
    // Issues → Pull Requests → Labels → Milestones → Releases → Workflow Runs.
    expect(y('Issues'), lessThan(y('Pull Requests')));
    expect(y('Pull Requests'), lessThan(y('Labels')));
    expect(y('Labels'), lessThan(y('Milestones')));
    expect(y('Milestones'), lessThan(y('Releases')));
    expect(y('Releases'), lessThan(y('Workflow Runs')));
  });

  testWidgets('selecting a PR opens its detail with actions', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Add the parser'));
    await tester.pumpAndSettle();

    expect(find.text('Check out'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    // Policy-aware primary may be Merge or Squash and merge.
    expect(
      find.text('Merge').evaluate().isNotEmpty ||
          find.text('Squash and merge').evaluate().isNotEmpty,
      isTrue,
    );
    expect(find.text('Head'), findsOneWidget);
    expect(find.text('Base'), findsOneWidget);
  });
  testWidgets('merge options sheet confirms squash path with SHA pin', (
    tester,
  ) async {
    final gh = _MergeCapturingGh();
    await _pump(tester, gh: gh);

    await tester.tap(find.text('Add the parser'));
    await tester.pumpAndSettle();
    // With full policy, squash is the default primary — open it directly.
    final squashPrimary = find.text('Squash and merge');
    if (squashPrimary.evaluate().isNotEmpty) {
      await tester.tap(squashPrimary.first);
    } else {
      await tester.tap(find.byType(MacosPulldownButton).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Squash and merge'));
    }
    await tester.pumpAndSettle();

    expect(gh.merges, isEmpty, reason: 'nothing before the confirm');
    // Phase-3 merge options sheet: confirm with Merge.
    expect(find.text('Merge pull request'), findsOneWidget);
    await tester.tap(find.text('Merge').last);
    await tester.pumpAndSettle();

    expect(gh.merges, [(7, 'squash', _readyPr.headOid)]);
  });
}
