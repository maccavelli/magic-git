// Verifies the (now inline) create-PR form pushes the head branch to origin *before* it
// calls `gh pr create` — `gh pr create --head` assumes the branch already
// exists on the remote (unlike `glab mr create`, which pushes implicitly), so
// creating a PR from a not-yet-pushed branch must still work.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/github/create_pr_form.dart';

const _repo = '/repo';

/// Shared, ordered record of the mutating calls the sheet makes, so a test can
/// assert push-then-create ordering.
final List<String> _calls = [];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  /// Local branches that "exist" — the form probes this (via [revParse] on
  /// `refs/heads/<name>`) to decide whether to push. Default: the head branch
  /// exists locally, so the push happens as before.
  Set<String> localRefs = {'refs/heads/feature'};

  @override
  Future<String?> revParse(String repoPath, String rev) async =>
      localRefs.contains(rev) ? 'oid-for-$rev' : null;

  @override
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async => 'diff for $range';

  @override
  Future<SSHCommandResult> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
    PushForce force = PushForce.none,
    bool followTags = false,
    CommandOutputCallback? onOutput,
  }) async {
    _calls.add('push $remote/$branch u=$setUpstream');
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

class _FakeGh extends GhService {
  _FakeGh() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<int?> createPullRequest(
    String repoPath, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
    List<String> reviewers = const [],
    List<String> assignees = const [],
    List<String> labels = const [],
    String? milestone,
  }) async {
    _calls.add('create $head->$base "$title"');
    return null;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  GhRepoMergePolicy policy = const GhRepoMergePolicy(),
  String? initialBase,
}) async {
  _calls.clear();
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit()),
      ghServiceProvider.overrideWithValue(_FakeGh()),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(head: 'feature'),
          files: const [],
        ),
      ),
      repoMergePolicyProvider(_repo).overrideWith((ref) async => policy),
      githubProjectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: CreatePrForm(
          repoPath: _repo,
          onClose: () {},
          initialBase: initialBase,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The Base field's live text (fields render in order: Head, Base, Title, …).
String _baseText(WidgetTester tester) => tester
    .widget<MacosTextField>(find.byType(MacosTextField).at(1))
    .controller!
    .text;

void main() {
  testWidgets('Create pushes the head branch before creating the PR', (
    tester,
  ) async {
    await _pump(tester);

    // Fields appear in order: Head, Base, Title, ... — head prefills to the
    // current branch ('feature'), base defaults to 'main'.
    await tester.enterText(find.byType(MacosTextField).at(2), 'My change');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Create pull request'));
    await tester.tap(find.text('Create pull request'));
    await tester.pumpAndSettle();

    expect(_calls, [
      'push origin/feature u=true',
      'create feature->main "My change"',
    ], reason: 'the branch must be pushed to origin before gh pr create');
  });

  // 0009 H12: the unseeded base comes from the repo's real default branch —
  // 'main' is only the last-resort fallback.
  testWidgets('base prefills from the merge policy default branch', (
    tester,
  ) async {
    await _pump(
      tester,
      policy: const GhRepoMergePolicy(defaultBranch: 'develop'),
    );
    expect(_baseText(tester), 'develop');
  });

  testWidgets('an explicit initialBase wins over the policy default', (
    tester,
  ) async {
    await _pump(
      tester,
      policy: const GhRepoMergePolicy(defaultBranch: 'develop'),
      initialBase: 'release',
    );
    expect(_baseText(tester), 'release');
  });

  testWidgets('no policy default falls back to main', (tester) async {
    await _pump(tester);
    expect(_baseText(tester), 'main');
  });
}
