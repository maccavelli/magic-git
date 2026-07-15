// DashboardSheet: the View → Dashboard View pop-up. Sections render from
// their providers independently, the on-demand footprint fetch runs only
// after Measure, and the X closes the sheet (whose route completion is what
// resets dashboardVisibleProvider in the shell).

import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/auth_status.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/dashboard/dashboard_sheet.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

Future<void> _pump(
  WidgetTester tester, {
  GitBranchInfo branch = const GitBranchInfo(
    head: 'main',
    upstream: 'origin/main',
    ahead: 2,
    behind: 1,
  ),
}) async {
  final state = ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: '/srv/repo',
    repoPaths: const ['/srv/repo'],
    connectionLabel: 'Prod',
    host: 'admdevops',
    connectedAt: DateTime.now().subtract(const Duration(minutes: 5)),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => _StubConnection(state)),
        statusProvider.overrideWith(
          (ref, repo) async => GitStatus(branch: branch, files: const []),
        ),
        logProvider.overrideWith((ref, repo) async => const []),
        forgeProvider.overrideWith((ref, repo) async => Forge.none),
        repoWatchProvider.overrideWith(
          (ref, repo) => Stream.value(
            RepoWatchEvent(at: DateTime.now(), mode: WatchMode.polling),
          ),
        ),
        localAuthStatusProvider.overrideWith(
          (ref) async => TargetAuth(
            label: 'This Mac',
            isLocal: true,
            git: parseGitVersion('git version 2.48.1', present: true),
            gh: parseGhAuthStatus(
              'github.com\n  ✓ Logged in to github.com account maccavelli\n'
              '  - Active account: true',
              present: true,
            ),
            glab: parseGlabAuthStatus(
              'gitlab.lkqdev.com\n  ✓ Logged in to gitlab.lkqdev.com as sax (c)',
              present: true,
            ),
          ),
        ),
        sessionAuthStatusProvider.overrideWith(
          (ref) async => TargetAuth(
            label: 'Prod (active session)',
            isLocal: false,
            git: parseGitVersion('git version 2.43.0', present: true),
            gh: parseGhAuthStatus('signed out', present: true),
            glab: parseGlabAuthStatus(
              'gitlab.lkqdev.com\n  ✓ Logged in to gitlab.lkqdev.com as sax (c)',
              present: true,
            ),
          ),
        ),
        repoFootprintProvider.overrideWith(
          (ref, repo) async => const RepoFootprint(
            looseObjects: 42,
            looseSize: '1.0 MiB',
            inPackObjects: 1000,
            packs: 2,
            packSize: '2.85 GiB',
          ),
        ),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(),
      ),
    ),
  );
  // Push the sheet as a real route so its X-close has something to pop to.
  final ctx = tester.element(find.byType(SizedBox).first);
  unawaited(
    Navigator.of(ctx).push(
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => const DashboardSheet()),
    ),
  );
  // Discrete pumps (not pumpAndSettle): the uptime ticker is periodic and
  // would keep the tree from ever settling.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('renders the session sections from live providers', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Dashboard'), findsOneWidget);
    // Connection card.
    expect(find.text('admdevops'), findsOneWidget);
    expect(find.text('Session uptime'), findsOneWidget);
    // Authentication section: local + the active remote target both render.
    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('This Mac'), findsOneWidget);
    expect(find.text('Prod (active session)'), findsOneWidget);
    // Latency section exists for an SSH session (still collecting).
    expect(find.text('Link latency (SSH keepalive)'), findsOneWidget);
    // Repository snapshot from the status stub.
    expect(find.text('main'), findsOneWidget);
    expect(find.text('↑2 ↓1'), findsOneWidget);
    // Command telemetry section.
    expect(find.text('Commands (this session)'), findsOneWidget);
    // Watcher state from the stream stub.
    expect(find.textContaining('Polling fallback'), findsOneWidget);

    // Close via the X so the periodic uptime ticker is disposed.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Close',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DashboardSheet), findsNothing);
  });

  testWidgets('an in-sync branch reads "in sync" — never "↑0 ↓0"', (
    tester,
  ) async {
    await _pump(
      tester,
      branch: const GitBranchInfo(head: 'main', upstream: 'origin/main'),
    );

    expect(find.text('in sync'), findsOneWidget);
    expect(find.textContaining('↑'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is MacosTooltip &&
            w.message == 'Even with origin/main — nothing to push or pull',
      ),
      findsOneWidget,
    );

    // Close via the X so the periodic uptime ticker is disposed.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Close',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the footprint fetch runs only after Measure', (tester) async {
    await _pump(tester);

    expect(find.text('2.85 GiB'), findsNothing);
    final measure = find.widgetWithText(PushButton, 'Measure');
    await tester.ensureVisible(measure);
    await tester.pump();
    await tester.tap(measure);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('2.85 GiB'), findsOneWidget);
    expect(find.text('42'), findsOneWidget); // loose objects

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Close',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DashboardSheet), findsNothing);
  });
}
