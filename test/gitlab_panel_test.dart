// Verifies the GitLab tab's left-pane / main-panel layout: MRs and pipelines
// list on the left; selecting one opens its detail on the right. Also pins the
// pipeline-row cleanup — no status word, no jobs/logs icon, retry icon only.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';

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

const _repo = '/repo';

final _mrs = [
  const MergeRequest(
    iid: 7,
    title: 'Add the parser',
    state: 'opened',
    authorUsername: 'alice',
    sourceBranch: 'feat',
    targetBranch: 'main',
    webUrl: '',
    draft: false,
  ),
];

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

Future<void> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
      pipelinesProvider(_repo).overrideWith((ref) async => _pipelines),
      jobsProvider((_repo, 100)).overrideWith((ref) async => _jobs),
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
    expect(find.text('Select a merge request or pipeline'), findsOneWidget);
  });

  testWidgets('selecting a pipeline opens its jobs in the main pane', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.textContaining('aaaaaaa1'));
    await tester.pumpAndSettle();

    expect(find.text('Select a merge request or pipeline'), findsNothing);
    expect(find.textContaining('Pipeline #100'), findsOneWidget);
    expect(find.text('build'), findsOneWidget); // job row
    expect(find.text('Select a job to view its log'), findsOneWidget);
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

  testWidgets(
    'Approve is replaced by a spinner while in flight — a second tap cannot '
    'fire a second concurrent approve call',
    (tester) async {
      final glab = _GatedGlab()..gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
          mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
          pipelinesProvider(_repo).overrideWith((ref) async => _pipelines),
          glabServiceProvider.overrideWithValue(glab),
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
      expect(find.text('Approve !7 on the remote GitLab project?'), findsOneWidget);

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
      const repoB = '/repo-b';
      final container = ProviderContainer(
        overrides: [
          refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
          refsProvider(repoB).overrideWith((ref) async => _remoteRefs),
          mergeRequestsProvider(_repo).overrideWith((ref) async => _mrs),
          pipelinesProvider(_repo).overrideWith((ref) async => _pipelines),
          jobsProvider((_repo, 100)).overrideWith((ref) async => _jobs),
          mergeRequestsProvider(repoB).overrideWith((ref) async => const []),
          pipelinesProvider(repoB).overrideWith((ref) async => const []),
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

      await tester.tap(find.textContaining('aaaaaaa1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pipeline #100'), findsOneWidget);

      // Same widget/State, new repoPath — exactly how AppShell re-renders
      // GitLabPanel when the active connection's repo changes.
      await tester.pumpWidget(host(repoB));
      await tester.pumpAndSettle();

      expect(find.text('Select a merge request or pipeline'), findsOneWidget);
      expect(find.textContaining('Pipeline #100'), findsNothing);
    },
  );
}
