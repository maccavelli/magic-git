// End-to-end wiring proof: tapping the Repository panel's Push button must feed
// the output log. Uses a fake GitService (no SSH) and asserts on the
// outputLogProvider state, so it exercises the real button -> _push ->
// _runLogged -> logResult path in repo_status_view.dart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

class _FakeGitService extends GitService {
  _FakeGitService({this.files = const []})
    : super(SSHCommandExecutor(SSHClientManager()));

  /// name-status lines the push "moved"; empty ⇒ nothing to report.
  final List<String> files;
  bool pushed = false;

  @override
  Future<SSHCommandResult> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
    PushForce force = PushForce.none,
    bool followTags = false,
  }) async {
    pushed = true;
    return const SSHCommandResult(
      exitCode: 0,
      stdout: '',
      stderr: 'To gitlab:me/repo.git\n   abc123..def456  main -> main',
    );
  }

  // With no files, report no base (skips the file list); otherwise return
  // distinct SHAs so a range exists.
  @override
  Future<String?> revParse(String repoPath, String rev) async =>
      files.isEmpty ? null : (rev == 'HEAD' ? 'newsha' : 'oldsha');

  @override
  Future<List<String>> changedFiles(String repoPath, String range) async =>
      files;

  // The panel probes this on mount; stub it so no real executor call (and its
  // timeout timer) is scheduled during the widget test.
  @override
  Future<PendingOp> pendingOp(String repoPath) async => PendingOp.none;
}

/// The file view is now open by default; this test doesn't exercise it, so keep
/// it hidden (otherwise it would call listWorkingTree on the fake git's real
/// executor and leak a timeout timer).
class _HiddenFileView extends FileViewVisibility {
  @override
  bool build() => false;
}

const _repo = '/srv/repo';

/// A connection pinned at `connected`. The sync group disables every verb
/// while the session is down — a git command against a dead transport can only
/// fail — so a test that presses Push has to model a live session.
class _ConnectedStub extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected);
}

// A remote-tracking ref so the header's `hasRemote` is true and the Push button
// is enabled (network actions are disabled when no remote is detected).
const _remoteRefs = [
  GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'deadbeef',
    isHead: false,
    subject: '',
  ),
];

Future<ProviderContainer> _mountAndPush(
  WidgetTester tester,
  _FakeGitService git,
) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(branch: const GitBranchInfo(), files: const []),
      ),
      repoWatchProvider(_repo).overrideWith(
        (ref) => const Stream<RepoWatchEvent>.empty(),
      ),
      fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
      refsProvider(_repo).overrideWith((ref) async => _remoteRefs),
      // Sibling of the refs override: the views now read CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs.
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      connectionProvider.overrideWith(_ConnectedStub.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: RepoStatusView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Push is now a labelled button in the context bar's sync group, not an
  // icon in a second toolbar band.
  await tester.tap(find.text('Push'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('tapping Push writes to the output log', (tester) async {
    const repo = '/srv/repo';
    final fakeGit = _FakeGitService();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(fakeGit),
        // Avoid real SSH from the status fetch and the remote watcher.
        statusProvider(repo).overrideWith(
          (ref) async => GitStatus(branch: const GitBranchInfo(), files: const []),
        ),
        repoWatchProvider(repo).overrideWith(
          (ref) => const Stream<RepoWatchEvent>.empty(),
        ),
        fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
        refsProvider(repo).overrideWith((ref) async => _remoteRefs),
        // Sibling of the refs override: the views now read CONFIGURED
        // remotes (remotesProvider), not remote-tracking refs.
        remotesProvider(repo).overrideWith((ref) async => const ['origin']),
        connectionProvider.overrideWith(_ConnectedStub.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: RepoStatusView(repoPath: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing logged before the tap.
    expect(container.read(outputLogProvider).lines, isEmpty);

    // Push is a labelled button in the context bar's sync group.
    final push = find.text('Push');
    expect(push, findsOneWidget);
    await tester.tap(push);
    await tester.pumpAndSettle();

    expect(fakeGit.pushed, isTrue, reason: 'Push button should call git.push');
    final lines = container.read(outputLogProvider).lines.map((l) => l.text).toList();
    expect(lines, contains('\$ git push'));
    expect(lines, contains('   abc123..def456  main -> main'));
    expect(lines, contains('✓ completed'));
  });

  testWidgets('push logs the list of pushed files', (tester) async {
    final container = await _mountAndPush(
      tester,
      _FakeGitService(files: const ['A\tlib/a.dart', 'M\tlib/b.dart']),
    );
    final lines = container.read(outputLogProvider).lines.map((l) => l.text);
    expect(lines, contains('Pushed — 2 files'));
    expect(lines.any((l) => l.contains('lib/a.dart')), isTrue);
    expect(lines.any((l) => l.contains('lib/b.dart')), isTrue);
  });
}
