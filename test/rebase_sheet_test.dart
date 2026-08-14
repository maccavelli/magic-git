// RebaseSheet: the action picker never offers Reword (structurally unusable
// given the headless GIT_EDITOR=true invocation), and — since interactive
// rebase is the highest-risk action here, able to squash/drop several commits
// in one shot — Rebase confirms before running, mirroring Reset/Amend/Revert
// elsewhere in the app.

import 'package:flutter/widgets.dart';
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

/// Long-press [source], drag it onto [target], and release — the interaction
/// the rebase rows use (long-press so the list still scrolls).
Future<void> _longDrag(
  WidgetTester tester,
  Finder source,
  Finder target,
) async {
  final gesture = await tester.startGesture(tester.getCenter(source));
  await tester.pump(const Duration(milliseconds: 600)); // exceed long-press
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Confirms the rebase and returns the steps handed to rebaseInteractive.
Future<List<RebaseStep>> _confirmAndCapture(
  WidgetTester tester,
  _FakeGit git,
) async {
  await tester.tap(find.text('Rebase'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.text('Rebase').last); // the dialog's confirm button
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return git.calls.single;
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

  testWidgets('the sheet footnotes that Reword is unavailable', (tester) async {
    await _pump(tester);

    expect(
      find.text(
        'Reword is unavailable — rebase runs without an editor, so '
        'it cannot prompt for a new message.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Rebase confirms before running, and cancelling does not call '
      'rebaseInteractive', (tester) async {
    final git = await _pump(tester);

    await tester.tap(find.text('Rebase'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Rebase'), findsWidgets); // dialog title/button
    expect(git.calls, isEmpty, reason: 'must not run before the user confirms');

    await tester.tap(find.text('Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(git.calls, isEmpty, reason: 'cancelling must not run the rebase');
  });

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

  testWidgets('dragging a commit into a gap reorders it', (tester) async {
    final git = await _pump(tester);

    // Drop "first" (row 0) into the gap after the last row -> it moves to the
    // end, so the steps come back second-then-first, both still pick.
    await _longDrag(
      tester,
      find.text('first'),
      find.byKey(const ValueKey('rebase-gap-2')),
    );

    final steps = await _confirmAndCapture(tester, git);
    expect(steps.map((s) => s.hash), ['bbb2222222', 'aaa1111111']);
    expect(steps.map((s) => s.action), [RebaseAction.pick, RebaseAction.pick]);
  });

  testWidgets('dropping a commit onto another squashes it in', (tester) async {
    final git = await _pump(tester);

    // Drop "second" onto "first": it stays just below and becomes squash.
    await _longDrag(
      tester,
      find.text('second'),
      find.byKey(const ValueKey('rebase-row-0')),
    );

    final steps = await _confirmAndCapture(tester, git);
    expect(steps.map((s) => s.hash), ['aaa1111111', 'bbb2222222']);
    expect(steps.map((s) => s.action), [
      RebaseAction.pick,
      RebaseAction.squash,
    ]);
  });

  testWidgets(
    'dropping the row a squash folds into resets the orphaned squash to pick',
    (tester) async {
      // The todo omits drop lines, so [drop, squash] would START with squash —
      // git rejects that ("cannot 'squash' without a previous commit"). The
      // sheet must normalize the first KEPT row, not merely the first row.
      final git = await _pump(tester);

      // second -> squash into first: rows are [first pick, second squash].
      await _longDrag(
        tester,
        find.text('second'),
        find.byKey(const ValueKey('rebase-row-0')),
      );

      // Now drop "first" via its action menu (row 0's pulldown).
      await tester.tap(find.text('Pick').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drop').last);
      await tester.pumpAndSettle();

      final steps = await _confirmAndCapture(tester, git);
      expect(steps.map((s) => s.hash), ['aaa1111111', 'bbb2222222']);
      expect(steps.map((s) => s.action), [
        RebaseAction.drop,
        RebaseAction.pick, // NOT squash — nothing kept above to fold into
      ]);
    },
  );
}
