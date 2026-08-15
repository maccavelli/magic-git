// The Forge Inbox (default view of the Forge tab): one triage list of open
// PRs/MRs, CI runs that need attention, and open issues — with type-chip
// filtering, pin-to-top, a snoozed group at the bottom (both persisted per
// repo), and the Browse sections one segment-click away.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/github/github_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';

final _prs = [
  const PullRequest(
    number: 7,
    title: 'Add the parser',
    state: 'open',
    merged: false,
    draft: false,
    authorLogin: 'alice',
    headRefName: 'feat',
    baseRefName: 'main',
    url: '',
  ),
  // A draft is blocked on the list tier alone — no detail fetch needed to
  // know GitHub will refuse to merge it.
  const PullRequest(
    number: 8,
    title: 'Still drafting',
    state: 'open',
    merged: false,
    draft: true,
    authorLogin: 'bob',
    headRefName: 'wip',
    baseRefName: 'main',
    url: '',
  ),
];

final _runs = [
  // Needs attention (failed) — belongs in the Inbox.
  const WorkflowRun(
    id: 201,
    status: 'completed',
    conclusion: 'failure',
    headBranch: 'feat',
    headSha: 'bbbbbbb2zzz',
    workflowName: 'Test',
    url: '',
  ),
  // Succeeded — not work; must stay out of the Inbox.
  const WorkflowRun(
    id: 200,
    status: 'completed',
    conclusion: 'success',
    headBranch: 'main',
    headSha: 'aaaaaaa1zzz',
    workflowName: 'Build',
    url: '',
  ),
];

const _issues = [
  ForgeIssue(id: 12, title: 'Fix login', state: 'opened', author: 'mac'),
];

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  addTearDown(() => SharedPreferences.setMockInitialValues({}));
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        // 0009 M6: the forge chrome names the real HEAD — stub status.
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'main'),
            files: const [],
          ),
        ),
        pullRequestsProvider(_repo).overrideWith((ref) async => _prs),
        workflowRunsProvider(_repo).overrideWith((ref) async => _runs),
        projectIssuesProvider(_repo).overrideWith((ref) async => _issues),
        projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
        githubProjectDashboardProvider(
          _repo,
        ).overrideWith((ref) async => const ForgeProjectDashboard()),
        originRemoteUrlProvider(_repo).overrideWith((ref) async => null),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: GitHubPanel(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _tool(String tooltip) =>
    find.byWidgetPredicate((w) => w is ToolIconButton && w.tooltip == tooltip);

void main() {
  testWidgets('the Inbox is the default view: PRs, failing/moving CI and '
      'issues — succeeded runs stay out', (tester) async {
    await _pump(tester);

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Add the parser'), findsOneWidget); // PR
    expect(find.text('Test'), findsOneWidget); // failed run
    expect(find.text('Fix login'), findsOneWidget); // issue
    expect(find.text('Build'), findsNothing); // succeeded run: not work
    // Browse-only chrome is absent.
    expect(find.text('Pull Requests'), findsNothing);
    expect(find.text('Milestones'), findsNothing);
  });

  testWidgets('type chips filter the Inbox to one category', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Issues'));
    await tester.pumpAndSettle();
    expect(find.text('Fix login'), findsOneWidget);
    expect(find.text('Add the parser'), findsNothing);
    expect(find.text('Test'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Add the parser'), findsOneWidget);
  });

  testWidgets('pinning floats an item into the Pinned group and persists', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Pinned'), findsNothing);

    // Pin the issue (the last row's pin button).
    await tester.tap(_tool('Pin to top').last);
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsOneWidget);
    // The pinned issue now renders ABOVE the PR row.
    final pinnedY = tester.getTopLeft(find.text('Fix login')).dy;
    final prY = tester.getTopLeft(find.text('Add the parser')).dy;
    expect(pinnedY, lessThan(prY));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('forgeInboxMarks_$_repo'), ['p:issue:12']);
  });

  testWidgets('snoozing sinks an item into a dimmed Snoozed group', (
    tester,
  ) async {
    await _pump(tester);

    // Snooze the PR (the first row's snooze button).
    await tester.tap(_tool('Snooze').first);
    await tester.pumpAndSettle();

    expect(find.text('Snoozed'), findsOneWidget);
    // The snoozed PR now renders BELOW the issue row.
    final prY = tester.getTopLeft(find.text('Add the parser')).dy;
    final issueY = tester.getTopLeft(find.text('Fix login')).dy;
    expect(prY, greaterThan(issueY));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('forgeInboxMarks_$_repo'), ['s:pr:7']);
  });

  testWidgets('the Browse segment switches to the full sections and persists', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();

    expect(find.text('Pull Requests'), findsOneWidget);
    expect(find.text('Workflow Runs'), findsOneWidget);
    expect(find.text('Milestones'), findsOneWidget);
    // The succeeded run is browsable even though the Inbox omits it.
    expect(find.text('Build'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('forgeInboxMode'), false);
  });

  testWidgets('"No blockers" hides change requests with a known blocker', (
    tester,
  ) async {
    await _pump(tester);

    // Both PRs are in the Inbox to begin with.
    expect(find.text('Add the parser'), findsOneWidget);
    expect(find.text('Still drafting'), findsOneWidget);

    await tester.tap(find.text('No blockers'));
    await tester.pumpAndSettle();

    // The draft is blocked; the clean PR survives. Evaluated from list-tier
    // data only — no detail provider is overridden in this harness, so a
    // per-row detail fetch would have thrown rather than filtered.
    expect(find.text('Add the parser'), findsOneWidget);
    expect(find.text('Still drafting'), findsNothing);
  });

  testWidgets('"No blockers" also drops CI and issue rows, which have nothing '
      'to merge', (tester) async {
    await _pump(tester);

    expect(find.text('Test'), findsOneWidget);
    expect(find.text('Fix login'), findsOneWidget);

    await tester.tap(find.text('No blockers'));
    await tester.pumpAndSettle();

    expect(find.text('Test'), findsNothing);
    expect(find.text('Fix login'), findsNothing);
  });

  testWidgets('"No blockers" is a toggle, not a radio — it can be switched '
      'back off', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('No blockers'));
    await tester.pumpAndSettle();
    expect(find.text('Still drafting'), findsNothing);

    await tester.tap(find.text('No blockers'));
    await tester.pumpAndSettle();
    expect(find.text('Still drafting'), findsOneWidget);
  });

  testWidgets('it composes with the kind chips rather than replacing them', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('No blockers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Issues'));
    await tester.pumpAndSettle();

    // Issues kind AND unblocked-only leaves nothing, and the empty state must
    // explain which lens emptied it.
    expect(find.text('Nothing is unblocked right now'), findsOneWidget);
  });
}
