import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/common/async_views.dart';
import 'package:remote_magic_git/features/common/dashboard_warning_banner.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/forge/forge_project_panel.dart';
import 'package:remote_magic_git/features/forge/project_dashboard_panel.dart';
import 'package:riverpod/misc.dart' show Override;

const _repo = '/repo';

const _dashboard = ForgeProjectDashboard(
  issues: [
    ForgeIssue(
      id: 606072,
      title: 'Fix flaky specs',
      state: 'opened',
      author: 'bob',
      labels: ['backend', 'mystery'],
    ),
  ],
  labels: [ForgeLabel(name: 'backend', color: '#34495E', description: 'BE')],
  milestones: [
    ForgeMilestone(id: 2, title: 'v0.5.0', state: 'active', due: '2026-07-22'),
  ],
  releases: [
    ForgeRelease(
      tagName: 'v19.0.2',
      name: 'Runner 19',
      publishedAt: '2026-07-01T17:57:10Z',
    ),
  ],
  issuesTotal: 2577,
  labelsTotal: 1, // fully shown → no "N of M"
  // milestonesTotal deliberately absent (GitLab exposes none) → no "N of M"
  releasesTotal: 272,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MacosApp(debugShowCheckedModeBanner: false, home: child),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders all four sections from one dashboard', (tester) async {
    var refreshes = 0;
    await _pump(
      tester,
      ProjectDashboardPanel(
        dashboard: const AsyncValue.data(_dashboard),
        onRefresh: () => refreshes++,
      ),
    );

    expect(find.text('#606072'), findsOneWidget);
    expect(find.text('Fix flaky specs'), findsOneWidget);
    expect(find.text('@bob'), findsOneWidget);
    // The issue's labels render as mini chips; 'backend' also appears in the
    // Labels section, 'mystery' (not in the fetched palette) only on the row.
    expect(find.text('backend'), findsNWidgets(2));
    expect(find.text('mystery'), findsOneWidget);
    expect(find.text('v0.5.0'), findsOneWidget);
    expect(find.text('due 2026-07-22'), findsOneWidget);
    expect(find.text('Runner 19'), findsOneWidget);
    // Release trailing caption carries tag AND publish date.
    expect(find.text('v19.0.2 · 2026-07-01'), findsOneWidget);

    // Every section's refresh refetches the (single) dashboard query.
    // (MacosIcon isn't an Icon, so find by the button type.)
    await tester.tap(find.byType(ToolIconButton).first);
    expect(refreshes, 1);
  });

  testWidgets('shows "N of M" only for truncated sections', (tester) async {
    await _pump(
      tester,
      ProjectDashboardPanel(
        dashboard: const AsyncValue.data(_dashboard),
        onRefresh: () {},
      ),
    );

    expect(find.text('1 of 2577'), findsOneWidget); // issues truncated
    expect(find.text('1 of 272'), findsOneWidget); // releases truncated
    expect(find.text('1 of 1'), findsNothing); // labels fully shown
    expect(
      find.textContaining(RegExp(r'of \d+')),
      findsNWidgets(2), // and no count at all for total-less milestones
    );
  });

  testWidgets('surfaces a partial-data warning carried on the result', (
    tester,
  ) async {
    await _pump(
      tester,
      ProjectDashboardPanel(
        dashboard: const AsyncValue.data(
          ForgeProjectDashboard(warning: 'dashboard: no access to field x'),
        ),
        onRefresh: () {},
      ),
    );
    expect(find.byType(DashboardWarningBanner), findsOneWidget);
    expect(
      find.textContaining('no access to field x'),
      findsOneWidget,
    );
    // Empty states still render beneath the warning.
    expect(find.text('No open issues'), findsOneWidget);
    expect(find.text('No open milestones'), findsOneWidget);
  });

  testWidgets('a failed dashboard renders the error, not empty sections', (
    tester,
  ) async {
    await _pump(
      tester,
      ProjectDashboardPanel(
        dashboard: AsyncValue.error(
          Exception('GitLab reports no project at "group/proj"'),
          StackTrace.current,
        ),
        onRefresh: () {},
      ),
    );
    expect(find.byType(SectionError), findsOneWidget);
    expect(find.text('No open issues'), findsNothing);
  });

  testWidgets(
    'ForgeProjectPanel routes a GitHub repo to the shared panel over the '
    'GitHub dashboard provider',
    (tester) async {
      await _pump(
        tester,
        const ForgeProjectPanel(repoPath: _repo),
        overrides: [
          forgeProvider(_repo).overrideWith((ref) async => Forge.github),
          githubProjectDashboardProvider(
            _repo,
          ).overrideWith((ref) async => _dashboard),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProjectDashboardPanel), findsOneWidget);
      expect(find.text('#606072'), findsOneWidget);
    },
  );

  testWidgets('ForgeProjectPanel shows NoRemoteNotice only for Forge.none', (
    tester,
  ) async {
    await _pump(
      tester,
      const ForgeProjectPanel(repoPath: _repo),
      overrides: [
        forgeProvider(_repo).overrideWith((ref) async => Forge.none),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byType(NoRemoteNotice), findsOneWidget);
  });
}
