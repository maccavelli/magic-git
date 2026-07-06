// Regression coverage for the MR-creation diff preview going stale: editing
// the source/target branch while the preview is open used to leave it showing
// the diff for whichever branches were selected when it was last
// opened/tapped, since the text fields only triggered a bare rebuild — never
// re-fetching the preview.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/gitlab/create_mr_sheet.dart';

const _repo = '/repo';

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> ranges = [];

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

Future<_FakeGit> _pump(WidgetTester tester) async {
  // The sheet's full content (title + scrollable form + button row) doesn't
  // fit the default 800x600 test surface, which both spams overflow warnings
  // and can leave lower content unhittable.
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      statusProvider(_repo).overrideWith(
        (ref) async =>
            GitStatus(branch: const GitBranchInfo(head: 'feature'), files: const []),
      ),
      // Otherwise this hits the real (unconfigured) GlabService and leaves a
      // retry backoff Timer pending past the test's teardown.
      projectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ProjectDashboard()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: CreateMrSheet(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets(
    'editing the target branch while the preview is open refreshes it, not '
    'just on the next manual toggle',
    (tester) async {
      final git = await _pump(tester);

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
      final git = await _pump(tester);

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
      final git = await _pump(tester);
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
}
