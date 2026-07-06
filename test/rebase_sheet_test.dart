// RebaseSheet: the action picker never offers Reword (structurally unusable
// given the headless GIT_EDITOR=true invocation), and — since interactive
// rebase is the highest-risk action here, able to squash/drop several commits
// in one shot — Rebase confirms before running, mirroring Reset/Amend/Revert
// elsewhere in the app.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/rebase_sheet.dart';

const _repo = '/repo';

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const ['base'],
  subject: subject,
);

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<List<RebaseStep>> calls = [];

  @override
  Future<SSHCommandResult> rebaseInteractive(
    String repoPath,
    String onto,
    List<RebaseStep> steps,
  ) async {
    calls.add(steps);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<_FakeGit> _pump(WidgetTester tester) async {
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: RebaseSheet(
          repoPath: _repo,
          onto: 'baseparenthash',
          commits: [_c('aaa1111111', 'first'), _c('bbb2222222', 'second')],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets('the action picker never offers Reword', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Pick').first);
    await tester.pumpAndSettle();

    expect(find.text('Squash'), findsWidgets);
    expect(find.text('Fixup'), findsWidgets);
    expect(find.text('Drop'), findsWidgets);
    expect(find.text('Reword'), findsNothing);
  });

  testWidgets(
    'Rebase confirms before running, and cancelling does not call '
    'rebaseInteractive',
    (tester) async {
      final git = await _pump(tester);

      await tester.tap(find.text('Rebase'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Rebase'), findsWidgets); // dialog title/button
      expect(
        git.calls,
        isEmpty,
        reason: 'must not run before the user confirms',
      );

      await tester.tap(find.text('Cancel').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(git.calls, isEmpty, reason: 'cancelling must not run the rebase');
    },
  );

  testWidgets('confirming runs rebaseInteractive with the picked steps', (
    tester,
  ) async {
    final git = await _pump(tester);

    await tester.tap(find.text('Rebase'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The dialog's own confirm button is the more-recently-added match.
    await tester.tap(find.text('Rebase').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(git.calls, hasLength(1));
    expect(git.calls.single.map((s) => s.action), [
      RebaseAction.pick,
      RebaseAction.pick,
    ]);
  });
}
