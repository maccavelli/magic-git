// Regression coverage for the (now inline) MR-creation form's diff preview going stale: editing
// the source/target branch while the preview is open used to leave it showing
// the diff for whichever branches were selected when it was last
// opened/tapped, since the text fields only triggered a bare rebuild — never
// re-fetching the preview.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/gitlab/create_mr_form.dart';

const _repo = '/repo';

class _FakeGlab extends GlabService {
  _FakeGlab() : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> created = [];

  @override
  Future<void> createMergeRequest(
    String repoPath, {
    required String sourceBranch,
    required String targetBranch,
    required String title,
    String description = '',
    bool draft = false,
    List<String> reviewers = const [],
    List<String> assignees = const [],
    List<String> labels = const [],
    String? milestone,
    bool squash = false,
    bool removeSourceBranch = false,
  }) async {
    created.add('$sourceBranch->$targetBranch:$title');
  }
}

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> ranges = [];
  final List<(String?, String?, bool)> pushes = [];

  /// When set, [push] blocks on this until completed — lets a test hold a
  /// submit "in flight" to observe the busy/disabled UI.
  Completer<void>? pushGate;

  @override
  Future<SSHCommandResult> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
    PushForce force = PushForce.none,
    bool followTags = false,
  }) async {
    pushes.add((remote, branch, setUpstream));
    if (pushGate != null) await pushGate!.future;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    ranges.add(range);
    return 'diff for $range';
  }
}

Future<(_FakeGit, _FakeGlab)> _pump(WidgetTester tester) async {
  // The sheet's full content (title + scrollable form + button row) doesn't
  // fit the default 800x600 test surface, which both spams overflow warnings
  // and can leave lower content unhittable.
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final git = _FakeGit();
  final glab = _FakeGlab();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      glabServiceProvider.overrideWithValue(glab),
      statusProvider(_repo).overrideWith(
        (ref) async =>
            GitStatus(branch: const GitBranchInfo(head: 'feature'), files: const []),
      ),
      // Otherwise this hits the real (unconfigured) GlabService and leaves a
      // retry backoff Timer pending past the test's teardown.
      projectDashboardProvider(
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
        home: CreateMrForm(repoPath: _repo, onClose: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (git, glab);
}

void main() {
  testWidgets(
    'editing the target branch while the preview is open refreshes it, not '
    'just on the next manual toggle',
    (tester) async {
      final (git, _) = await _pump(tester);

      // Source is prefilled from the current branch ('feature'); target
      // defaults to 'main'. Fields appear in form order: Source, Target, ...
      final targetField = find.byType(MacosTextField).at(1);

      // "Preview changes" sits below the fold of the form's own bounded
      // scroll area.
      await tester.ensureVisible(find.text('Preview changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview changes'));
      await tester.pumpAndSettle();
      expect(git.ranges, ['main...feature']);

      // Change the target branch while the preview is still open.
      await tester.enterText(targetField, 'develop');
      await tester.pumpAndSettle();

      expect(
        git.ranges,
        ['main...feature', 'develop...feature'],
        reason: 'the preview must refresh to match the new target branch',
      );
    },
  );

  testWidgets(
    'editing branches while the preview is closed does not fetch a preview '
    'at all',
    (tester) async {
      final (git, _) = await _pump(tester);

      final targetField = find.byType(MacosTextField).at(1);
      await tester.enterText(targetField, 'develop');
      await tester.pumpAndSettle();

      expect(git.ranges, isEmpty);
    },
  );

  testWidgets(
    'rapid keystrokes while the preview is open are debounced into a single '
    'diff fetch, not one per keystroke',
    (tester) async {
      final (git, _) = await _pump(tester);
      final targetField = find.byType(MacosTextField).at(1);

      await tester.ensureVisible(find.text('Preview changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview changes'));
      await tester.pumpAndSettle();
      expect(git.ranges, ['main...feature']);

      // Simulate typing "dev" one character at a time, each within the
      // debounce window — only the final value should ever be fetched.
      await tester.enterText(targetField, 'd');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(targetField, 'de');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(targetField, 'dev');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        git.ranges,
        ['main...feature'],
        reason: 'no fetch yet — still inside the debounce window',
      );

      await tester.pumpAndSettle();
      expect(
        git.ranges,
        ['main...feature', 'dev...feature'],
        reason: 'exactly one fetch, for the final value only',
      );
    },
  );
  testWidgets('Create pushes the source branch (with upstream) BEFORE the MR '
      'is created', (tester) async {
    // The GitLab API needs the branch on the remote first; `glab mr create`
    // only pushes behind an opt-in flag this sheet never passes — an unpushed
    // branch used to die with a raw API error.
    final (git, glab) = await _pump(tester);

    await tester.enterText(
      find.byType(MacosTextField).at(2), // title — source/target prefilled
      'My change',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppPushButton, 'Create merge request'));
    await tester.pumpAndSettle();

    expect(git.pushes, [('origin', 'feature', true)]);
    expect(glab.created, ['feature->main:My change']);
  });

  testWidgets('Cancel is disabled while a submit is in flight (#4)', (
    tester,
  ) async {
    final (git, glab) = await _pump(tester);
    git.pushGate = Completer<void>(); // hold the submit open at the push

    await tester.enterText(find.byType(MacosTextField).at(2), 'My change');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppPushButton, 'Create merge request'));
    await tester.pump(); // enters _submitting; push is now awaiting the gate

    final cancel = tester.widget<AppPushButton>(
      find.widgetWithText(AppPushButton, 'Cancel'),
    );
    expect(
      cancel.onPressed,
      isNull,
      reason: 'a create in flight must not be cancellable (would orphan it)',
    );
    expect(find.byType(ProgressCircle), findsWidgets);

    // Release the push: the MR completes (never orphaned) and the busy state
    // clears.
    git.pushGate!.complete();
    await tester.pumpAndSettle();
    expect(glab.created, ['feature->main:My change']);
  });

  testWidgets('the source branch prefills after status resolves, without a '
      'build-time crash (#12)', (tester) async {
    // _pump's statusProvider resolves asynchronously — the field mounts first,
    // then status arrives; the prefill must land (and not throw a
    // setState-during-build).
    await _pump(tester);
    final source = tester.widget<MacosTextField>(
      find.byType(MacosTextField).first,
    );
    expect(source.controller?.text, 'feature');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a selected milestone that vanishes on reload does not crash the '
      'picker (#5)', (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var first = true;
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_FakeGit()),
        glabServiceProvider.overrideWithValue(_FakeGlab()),
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'feature'),
            files: const [],
          ),
        ),
        projectDashboardProvider(_repo).overrideWith(
          (ref) async => first
              ? const ForgeProjectDashboard(
                  milestones: [
                    ForgeMilestone(id: 5, title: 'v1', state: 'active'),
                  ],
                )
              // Reloads with a DIFFERENT milestone set — the selected id 5 is
              // gone; passing it to the popup would assert without coercion.
              : const ForgeProjectDashboard(
                  milestones: [
                    ForgeMilestone(id: 7, title: 'v2', state: 'active'),
                  ],
                ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: CreateMrForm(repoPath: _repo, onClose: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Select milestone v1 (id 5).
    await tester.ensureVisible(find.text('Milestone'));
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1').last);
    await tester.pumpAndSettle();

    // The dashboard reloads without v1.
    first = false;
    container.invalidate(projectDashboardProvider(_repo));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the vanished selection must be coerced to null, not asserted',
    );
  });
}
