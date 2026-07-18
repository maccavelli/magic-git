// The Project tab's master-detail panel: a forge-neutral left pane (issues +
// milestones paginated, labels + releases from the dashboard) and a right pane
// that opens the selected issue/milestone or an inline new-issue form.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/common/async_views.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/dashboard_warning_banner.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/forge/forge_panel.dart'
    show UnsupportedForgeNotice;
import 'package:remote_magic_git/features/forge/forge_project_panel.dart';
import 'package:riverpod/misc.dart' show Override;

const _repo = '/repo';

const _issues = [
  ForgeIssue(
    id: 12,
    title: 'Fix login',
    state: 'opened',
    author: 'mac',
    labels: ['bug'],
  ),
  ForgeIssue(id: 9, title: 'Slow diff', state: 'opened', author: 'sam'),
];

const _milestones = [
  ForgeMilestone(
    id: 3,
    title: 'v1.0',
    state: 'active',
    due: '2026-08-01',
    description: 'First release',
  ),
];

const _dashboard = ForgeProjectDashboard(
  labels: [ForgeLabel(name: 'bug', color: '#d73a4a')],
  releases: [
    ForgeRelease(
      tagName: 'v0.9',
      name: 'Beta',
      publishedAt: '2026-07-01T00:00:00Z',
    ),
  ],
);

const _issue12Detail = ForgeIssue(
  id: 12,
  title: 'Fix login',
  state: 'opened',
  author: 'mac',
  labels: ['bug'],
  body: 'Steps to reproduce the bug',
);

List<Override> _overrides({Forge forge = Forge.github}) => [
  forgeProvider(_repo).overrideWith((ref) async => forge),
  projectIssuesProvider(_repo).overrideWith((ref) async => _issues),
  projectMilestonesProvider(_repo).overrideWith((ref) async => _milestones),
  githubProjectDashboardProvider(_repo).overrideWith((ref) async => _dashboard),
  issueDetailProvider((_repo, 12)).overrideWith((ref) async => _issue12Detail),
];

Future<void> _pump(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: ForgeProjectPanel(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('left pane lists issues, milestones, labels and releases', (
    tester,
  ) async {
    await _pump(tester, overrides: _overrides());

    expect(find.text('Fix login'), findsOneWidget);
    expect(find.text('#12'), findsOneWidget);
    expect(find.text('@mac'), findsOneWidget);
    expect(find.text('Slow diff'), findsOneWidget);
    expect(find.text('v1.0'), findsOneWidget);
    expect(find.text('due 2026-08-01'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    // 'bug' shows in the Labels section AND as issue #12's mini chip.
    expect(find.text('bug'), findsNWidgets(2));
    // Nothing selected yet.
    expect(
      find.text('Select an issue or milestone, or add one'),
      findsOneWidget,
    );
  });

  testWidgets('selecting an issue opens its detail with the fetched body', (
    tester,
  ) async {
    await _pump(tester, overrides: _overrides());

    await tester.tap(find.text('Fix login'));
    await tester.pumpAndSettle();

    // The lazily-fetched body lands in the detail pane.
    expect(find.text('Steps to reproduce the bug'), findsOneWidget);
    // Title now appears twice: the left-pane row and the detail header.
    expect(find.text('Fix login'), findsNWidgets(2));
    expect(
      find.text('Select an issue or milestone, or add one'),
      findsNothing,
    );
  });

  testWidgets('selecting a milestone opens its detail with the description', (
    tester,
  ) async {
    await _pump(tester, overrides: _overrides());

    await tester.tap(find.text('v1.0'));
    await tester.pumpAndSettle();

    expect(find.text('First release'), findsOneWidget); // description body
  });

  testWidgets('the Issues "+" opens the inline create form in the right pane', (
    tester,
  ) async {
    await _pump(tester, overrides: _overrides());

    // The Issues section header is first; its add button precedes its refresh.
    await tester.tap(find.byType(ToolIconButton).first);
    await tester.pumpAndSettle();

    expect(find.text('New Issue'), findsOneWidget);
    expect(find.widgetWithText(AppPushButton, 'Create issue'), findsOneWidget);
  });

  testWidgets('a dirty draft asks before a row click discards it', (
    tester,
  ) async {
    await _pump(tester, overrides: _overrides());

    // Open the create form and type something.
    await tester.tap(find.byType(ToolIconButton).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(MacosTextField).first, 'Half-typed bug');
    await tester.pump();

    // Clicking an issue row now confirms instead of nuking the draft.
    await tester.tap(find.text('Fix login'));
    await tester.pumpAndSettle();
    expect(find.text('Discard draft issue?'), findsOneWidget);

    // Keep editing → draft (and its text) survive.
    await tester.tap(find.text('Keep Editing'));
    await tester.pumpAndSettle();
    expect(find.text('New Issue'), findsOneWidget);
    expect(find.text('Half-typed bug'), findsOneWidget);

    // Discard → the clicked issue's detail opens.
    await tester.tap(find.text('Fix login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard Draft'));
    await tester.pumpAndSettle();
    expect(find.text('New Issue'), findsNothing);
    expect(find.text('Steps to reproduce the bug'), findsOneWidget);
  });

  testWidgets('a clean create form opens a row without asking', (
    tester,
  ) async {
    await _pump(tester, overrides: _overrides());

    await tester.tap(find.byType(ToolIconButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix login'));
    await tester.pumpAndSettle();

    expect(find.text('Discard draft issue?'), findsNothing);
    expect(find.text('Steps to reproduce the bug'), findsOneWidget);
  });

  testWidgets('tab-away keeps a dirty draft mounted, clears a clean one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var active = true;
    late StateSetter setHarness;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: StatefulBuilder(
            builder: (context, setState) {
              setHarness = setState;
              return ForgeProjectPanel(repoPath: _repo, isActive: active);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Dirty draft: leaving and returning to the tab preserves the text.
    await tester.tap(find.byType(ToolIconButton).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(MacosTextField).first, 'Keep me');
    await tester.pump();
    setHarness(() => active = false);
    await tester.pumpAndSettle();
    setHarness(() => active = true);
    await tester.pumpAndSettle();
    expect(find.text('Keep me'), findsOneWidget);

    // Clean form (Cancel first): tab-away resets to the neutral hint.
    await tester.tap(find.widgetWithText(AppPushButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ToolIconButton).first);
    await tester.pumpAndSettle();
    setHarness(() => active = false);
    await tester.pumpAndSettle();
    setHarness(() => active = true);
    await tester.pumpAndSettle();
    expect(find.text('New Issue'), findsNothing);
    expect(
      find.text('Select an issue or milestone, or add one'),
      findsOneWidget,
    );
  });

  testWidgets('a failed dashboard surfaces errors, not silent empties', (
    tester,
  ) async {
    await _pump(
      tester,
      overrides: [
        forgeProvider(_repo).overrideWith((ref) async => Forge.github),
        projectIssuesProvider(_repo).overrideWith((ref) async => _issues),
        projectMilestonesProvider(
          _repo,
        ).overrideWith((ref) async => _milestones),
        githubProjectDashboardProvider(
          _repo,
        ).overrideWith((ref) async => throw Exception('dashboard down')),
      ],
    );

    // Labels and Releases each render the failure inline; neither pretends
    // the project simply has none.
    expect(find.byType(SectionError), findsNWidgets(2));
    expect(find.text('No labels'), findsNothing);
    expect(find.text('No releases'), findsNothing);
  });

  testWidgets('a loading dashboard shows spinners, not "No labels"', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final never = Completer<ForgeProjectDashboard>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          forgeProvider(_repo).overrideWith((ref) async => Forge.github),
          projectIssuesProvider(_repo).overrideWith((ref) async => _issues),
          projectMilestonesProvider(
            _repo,
          ).overrideWith((ref) async => _milestones),
          githubProjectDashboardProvider(
            _repo,
          ).overrideWith((ref) => never.future),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: ForgeProjectPanel(repoPath: _repo),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No labels'), findsNothing);
    expect(find.text('No releases'), findsNothing);
    expect(find.byType(SectionLoading), findsAtLeastNWidgets(2));
  });

  testWidgets('the partial-data warning banner shows in the left pane', (
    tester,
  ) async {
    const warned = ForgeProjectDashboard(
      labels: [ForgeLabel(name: 'bug', color: '#d73a4a')],
      warning: 'insufficient scopes on labels',
    );
    await _pump(
      tester,
      overrides: [
        forgeProvider(_repo).overrideWith((ref) async => Forge.github),
        projectIssuesProvider(_repo).overrideWith((ref) async => _issues),
        projectMilestonesProvider(
          _repo,
        ).overrideWith((ref) async => _milestones),
        githubProjectDashboardProvider(
          _repo,
        ).overrideWith((ref) async => warned),
      ],
    );
    expect(find.byType(DashboardWarningBanner), findsOneWidget);
  });

  testWidgets('section headers show "N of M" when the forge total is larger', (
    tester,
  ) async {
    const counted = ForgeProjectDashboard(
      labels: [ForgeLabel(name: 'bug', color: '#d73a4a')],
      issuesTotal: 974,
      labelsTotal: 250,
    );
    await _pump(
      tester,
      overrides: [
        forgeProvider(_repo).overrideWith((ref) async => Forge.github),
        projectIssuesProvider(_repo).overrideWith((ref) async => _issues),
        projectMilestonesProvider(
          _repo,
        ).overrideWith((ref) async => _milestones),
        githubProjectDashboardProvider(
          _repo,
        ).overrideWith((ref) async => counted),
      ],
    );
    expect(find.text('2 of 974'), findsOneWidget); // issues header
    expect(find.text('1 of 250'), findsOneWidget); // labels header
  });

  testWidgets('Forge.none shows the no-remote notice, not the workspace', (
    tester,
  ) async {
    await _pump(
      tester,
      overrides: [forgeProvider(_repo).overrideWith((ref) async => Forge.none)],
    );
    expect(find.byType(NoRemoteNotice), findsOneWidget);
    expect(find.text('Issues'), findsNothing);
  });

  testWidgets('Forge.unknown shows the unsupported-forge notice', (
    tester,
  ) async {
    await _pump(
      tester,
      overrides: [
        forgeProvider(_repo).overrideWith((ref) async => Forge.unknown),
      ],
    );
    expect(find.byType(UnsupportedForgeNotice), findsOneWidget);
  });
}
