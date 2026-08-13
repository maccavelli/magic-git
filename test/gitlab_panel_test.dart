// Verifies the GitLab tab's left-pane / main-panel layout: MRs and pipelines
// list on the left; selecting one opens its detail on the right. Also pins the
// pipeline-row cleanup — no status word, no jobs/logs icon, retry icon only.

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/workspace_focus.dart';
import 'package:remote_magic_git/features/common/workspace_navigation.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Records approveMergeRequest calls and, while [gate] is set, pauses before
/// returning — lets a test observe the panel's in-flight state and prove a
/// second tap can't fire a second call while the first is still pending.
class _GatedGlab extends GlabService {
  _GatedGlab() : super(SSHCommandExecutor(SSHClientManager()));
  int approveCalls = 0;
  Completer<void>? gate;

  @override
  Future<void> approveMergeRequest(String repoPath, int iid) async {
    approveCalls++;
    if (gate != null) await gate!.future;
  }
}

/// Records mergeMergeRequest calls as (iid, squash, sha) triples.
class _MergeCapturingGlab extends GlabService {
  _MergeCapturingGlab() : super(SSHCommandExecutor(SSHClientManager()));
  final merges = <(int, bool, String?)>[];

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
    merges.add((iid, squash, sha));
  }

  @override
  Future<MergeRequest> mergeRequestDetail(String repoPath, int iid) async {
    return _readyMr;
  }
}

const _repo = '/repo';

const _readyMr = MergeRequest(
  iid: 7,
  title: 'Add the parser',
  state: 'opened',
  authorUsername: 'alice',
  sourceBranch: 'feat',
  targetBranch: 'main',
  webUrl: '',
  draft: false,
  sha: 'abcdef0123456789abcdef0123456789abcdef01',
  detailedMergeStatus: 'mergeable',
  hasConflicts: false,
);

final _mrs = [_readyMr];

final _pipelines = [
  const Pipeline(
    id: 100,
    status: 'success',
    ref: 'main',
    sha: 'aaaaaaa1zzz',
    webUrl: '',
  ),
  const Pipeline(
    id: 101,
    status: 'failed',
    ref: 'feat',
    sha: 'bbbbbbb2zzz',
    webUrl: '',
  ),
];

final _jobs = [
  const Job(id: 900, name: 'build', stage: 'build', status: 'success'),
];

// A remote-tracking ref so the panel's "no remote → NoRemoteNotice" gate
// (GitLabPanel.build) treats the repo as having a remote and renders the
// MR/pipeline views these tests assert on.
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

class _Connected extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _repo,
    sessionEpoch: 7,
  );
}

/// The unified Forge panel also renders the project sections — settle their
/// providers so no section is left spinning (pumpAndSettle would hang).
/// (The Browse-mode override lives at each container, not here — this helper
/// is spread once per repo and a container may cover two repos.)
List<Override> _projectOverrides(String repo) => [
  projectIssuesProvider(repo).overrideWith((ref) async => const []),
  projectMilestonesProvider(repo).overrideWith((ref) async => const []),
  projectDashboardProvider(
    repo,
  ).overrideWith((ref) async => const ForgeProjectDashboard()),
  originRemoteUrlProvider(repo).overrideWith((ref) async => null),
];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  GlabService? glab,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      connectionProvider.overrideWith(_Connected.new),
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      if (glab != null) glabServiceProvider.overrideWithValue(glab),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      // Sibling of the refs override: the views now read CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs.
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
      mergeRequestDetailProvider((
        _repo,
        7,
      )).overrideWith((ref) async => _readyMr),
      repoMergePolicyProvider(
        _repo,
      ).overrideWith((ref) async => const GlRepoMergePolicy()),
      pipelinesProvider(_repo).overrideWith((ref) async => _pipelines),
      jobsProvider((_repo, 100)).overrideWith((ref) async => _jobs),
      // The MR detail's inline Checks body mounts the head pipeline's jobs
      // (pipeline 101 — ref 'feat' matches the MR's source branch).
      jobsProvider((_repo, 101)).overrideWith((ref) async => _jobs),
      ..._projectOverrides(_repo),
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
  return container;
}

/// ToolIconButton / status dots use macos_ui's MacosIcon, which find.byIcon
/// (material Icon only) does not match.
Finder _macosIcon(IconData d) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == d);

void main() {
  testWidgets('lists MRs and pipelines; pipeline row has no status word or '
      'jobs/logs icon, retry only when retryable', (tester) async {
    await _pump(tester);

    expect(find.text('Merge Requests'), findsOneWidget);
    expect(find.text('Pipelines'), findsOneWidget);
    expect(find.text('Add the parser'), findsOneWidget);
    expect(find.textContaining('aaaaaaa1'), findsOneWidget); // pipeline ref·sha

    // Status word removed; jobs/logs (doc_text) icon removed.
    expect(find.text('success'), findsNothing);
    expect(find.text('failed'), findsNothing);
    expect(_macosIcon(CupertinoIcons.doc_text), findsNothing);
    // Exactly one retry icon — for the single failed pipeline.
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

  testWidgets('selecting a pipeline opens its jobs in the main pane', (
    tester,
  ) async {
    final container = await _pump(tester);
    await tester.ensureVisible(find.textContaining('aaaaaaa1'));
    await tester.tap(find.textContaining('aaaaaaa1'));
    await tester.pumpAndSettle();

    expect(find.text('Select an item on the left'), findsNothing);
    expect(find.textContaining('Pipeline #100'), findsOneWidget);
    expect(find.text('build'), findsOneWidget); // job row
    expect(find.text('Select a job to view its log'), findsOneWidget);
    expect(
      container
          .read(repositoryContextSupplementCacheProvider)
          .values
          .single
          .selectionLabel,
      'GitLab CI run 100',
    );
    final focus = container
        .read(workspaceNavigationProvider(const WorkspaceSessionKey(_repo, 7)))
        .current;
    expect(focus?.kind, WorkspaceFocusKind.pipeline);
    expect(focus?.identity, '100');
    expect(focus?.panelIndex, 4);
  });

  testWidgets('left-pane sections list in the canonical order', (tester) async {
    await _pump(tester);
    double y(String label) => tester.getTopLeft(find.text(label)).dy;
    // Issues → Merge Requests → Labels → Milestones → Releases → Pipelines.
    expect(y('Issues'), lessThan(y('Merge Requests')));
    expect(y('Merge Requests'), lessThan(y('Labels')));
    expect(y('Labels'), lessThan(y('Milestones')));
    expect(y('Milestones'), lessThan(y('Releases')));
    expect(y('Releases'), lessThan(y('Pipelines')));
  });

  testWidgets('selecting an MR opens its detail with actions', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Add the parser'));
    await tester.pumpAndSettle();

    expect(find.text('Check out'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    // Detail lines.
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Target'), findsOneWidget);
  });

  testWidgets('the merge pulldown offers squash, confirmed via options sheet', (
    tester,
  ) async {
    // The GitLab merge API always supported squash=true; the UI only ever
    // sent the default. The pulldown beside Merge closes that gap (no rebase
    // entry — on GitLab that's a project setting, not a per-merge choice).
    final glab = _MergeCapturingGlab();
    await _pump(tester, glab: glab);

    await tester.tap(find.text('Add the parser'));
    await tester.pumpAndSettle();
    // The merge-strategy pulldown is the first in the action bar; the "More"
    // overflow pulldown is the last.
    await tester.tap(find.byType(MacosPulldownButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Squash and merge'));
    await tester.pumpAndSettle();

    expect(glab.merges, isEmpty, reason: 'nothing before the confirm');
    expect(find.text('Merge merge request'), findsOneWidget);
    await tester.tap(find.text('Merge').last);
    await tester.pumpAndSettle();

    expect(glab.merges, [(7, true, _readyMr.sha)]);
  });

  testWidgets(
    'Approve is replaced by a spinner while in flight — a second tap cannot '
    'fire a second concurrent approve call',
    (tester) async {
      final glab = _GatedGlab()..gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          forgeInboxModeProvider.overrideWith(_BrowseMode.new),
          refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
          mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
          mergeRequestDetailProvider((
            _repo,
            7,
          )).overrideWith((ref) async => _readyMr),
          repoMergePolicyProvider(
            _repo,
          ).overrideWith((ref) async => const GlRepoMergePolicy()),
          pipelinesProvider(_repo).overrideWith((ref) async => _pipelines),
          jobsProvider((_repo, 101)).overrideWith((ref) async => _jobs),
          glabServiceProvider.overrideWithValue(glab),
          ..._projectOverrides(_repo),
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

      await tester.tap(find.text('Add the parser'));
      await tester.pumpAndSettle();
      expect(find.text('Approve'), findsOneWidget);

      // Open the confirm dialog.
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(
        find.text('Approve !7 on the remote GitLab project?'),
        findsOneWidget,
      );

      // Confirm — the dialog's own button is the more-recently-added match.
      await tester.tap(find.text('Approve').last);
      await tester.pump(); // process the tap / start the dialog's pop
      // Advance past the dialog's exit transition without pumpAndSettle,
      // which would hang forever on the ProgressCircle's own perpetual spin
      // once it appears.
      await tester.pump(const Duration(seconds: 1));

      expect(glab.approveCalls, 1);
      expect(
        find.text('Approve'),
        findsNothing,
        reason: 'the button is replaced by a spinner while in flight',
      );
      expect(find.byType(ProgressCircle), findsOneWidget);

      // Release the gate — the mutation completes and the button returns.
      glab.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        glab.approveCalls,
        1,
        reason: 'still exactly one call — there was no way to double-submit',
      );
      expect(find.text('Approve'), findsOneWidget);
    },
  );

  testWidgets(
    'switching the active repo clears the selected pipeline (and its detail '
    "pane), since the panel isn't repo-keyed and this State survives the "
    'switch',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const repoB = '/repo-b';
      final container = ProviderContainer(
        overrides: [
          forgeInboxModeProvider.overrideWith(_BrowseMode.new),
          refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
          refsProvider(repoB).overrideWith((ref) async => _remoteRefs),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(repoB).overrideWith((ref) async => const ['origin']),
          mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
          pipelinesProvider(_repo).overrideWith((ref) async => _pipelines),
          jobsProvider((_repo, 100)).overrideWith((ref) async => _jobs),
          mergeRequestsProvider(repoB).overrideWith((ref) async => const []),
          pipelinesProvider(repoB).overrideWith((ref) async => const []),
          ..._projectOverrides(_repo),
          ..._projectOverrides(repoB),
        ],
      );
      addTearDown(container.dispose);

      Widget host(String repoPath) => UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 1100,
            height: 720,
            child: GitLabPanel(repoPath: repoPath),
          ),
        ),
      );

      await tester.pumpWidget(host(_repo));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.textContaining('aaaaaaa1'));
      await tester.tap(find.textContaining('aaaaaaa1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pipeline #100'), findsOneWidget);

      // Same widget/State, new repoPath — exactly how AppShell re-renders
      // GitLabPanel when the active connection's repo changes.
      await tester.pumpWidget(host(repoB));
      await tester.pumpAndSettle();

      expect(find.text('Select an item on the left'), findsOneWidget);
      expect(find.textContaining('Pipeline #100'), findsNothing);
    },
  );

  group('prettyPipelineRef', () {
    test('decodes GitLab merge-request pipeline refs', () {
      expect(prettyPipelineRef('refs/merge-requests/7/head'), 'MR !7');
      expect(
        prettyPipelineRef('refs/merge-requests/42/merge'),
        'MR !42 (merged results)',
      );
    });

    test('passes an ordinary branch ref through unchanged', () {
      expect(prettyPipelineRef('main'), 'main');
      expect(prettyPipelineRef('feat/x'), 'feat/x');
      // A malformed lookalike is not decoded.
      expect(
        prettyPipelineRef('refs/merge-requests/x/head'),
        'refs/merge-requests/x/head',
      );
    });
  });
}
