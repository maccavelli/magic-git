// Drag-a-branch-to-merge/rebase in the History view: dragging a branch chip
// onto a commit row opens an integrate menu whose actions run merge / rebase
// against the current branch. Uses a fake GitService so no SSH is touched.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DragFakeGit extends GitService {
  _DragFakeGit(this.commits, this.refList)
    : super(SSHCommandExecutor(SSHClientManager()));
  final List<GitCommit> commits;
  final List<GitRef> refList;

  final mergedBranches = <(String, MergeMode)>[];
  final rebasedOnto = <String>[];
  final movedBranches = <(String, String)>[];

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => commits;

  @override
  Future<List<GitRef>> refs(String repoPath) async => refList;

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) async {
    mergedBranches.add((branch, mode));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> rebaseOnto(String repoPath, String upstream) async {
    rebasedOnto.add(upstream);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> moveBranch(
    String repoPath,
    String name,
    String targetOid,
  ) async {
    movedBranches.add((name, targetOid));
  }
}

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

const _repo = '/srv/repo';

Future<_DragFakeGit> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final head = _c('aaaaaaa1111111', 'head commit');
  final older = _c('bbbbbbb2222222', 'old commit');
  final git = _DragFakeGit(
    [head, older],
    [
      GitRef(
        name: 'refs/heads/main',
        oid: head.hash,
        isHead: true,
        subject: 's',
      ),
      GitRef(
        name: 'refs/heads/feature',
        oid: older.hash,
        isHead: false,
        subject: 's',
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      repoWatchProvider.overrideWith((ref, repoPath) => const Stream.empty()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: HistoryView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

/// Drags the [chip] finder onto the [target] finder via a manual gesture (a
/// simple `tester.drag` delta doesn't reliably cross the Draggable slop then
/// settle over the DragTarget).
Future<void> _dragOnto(WidgetTester tester, Finder chip, Finder target) async {
  final from = tester.getCenter(chip);
  final to = tester.getCenter(target);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // exceed touch slop, start drag
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dropping a branch chip opens the integrate menu', (
    tester,
  ) async {
    await _pump(tester);
    await _dragOnto(tester, find.text('feature'), find.text('head commit'));
    expect(find.text('Merge feature into main'), findsOneWidget);
    expect(find.text('Merge feature into main (squash)'), findsOneWidget);
    expect(find.text('Rebase main onto feature'), findsOneWidget);
    expect(find.text('Move feature here'), findsOneWidget);
  });

  testWidgets('choosing Merge runs git merge of the dragged branch', (
    tester,
  ) async {
    final git = await _pump(tester);
    await _dragOnto(tester, find.text('feature'), find.text('head commit'));
    await tester.tap(find.text('Merge feature into main'));
    await tester.pumpAndSettle();
    expect(git.mergedBranches, [('feature', MergeMode.normal)]);
    expect(git.rebasedOnto, isEmpty);
  });

  testWidgets('choosing Rebase runs git rebase onto the dragged branch', (
    tester,
  ) async {
    final git = await _pump(tester);
    await _dragOnto(tester, find.text('feature'), find.text('head commit'));
    await tester.tap(find.text('Rebase main onto feature'));
    await tester.pumpAndSettle();
    expect(git.rebasedOnto, ['feature']);
    expect(git.mergedBranches, isEmpty);
  });

  testWidgets('choosing Move branch here confirms then moves the tip', (
    tester,
  ) async {
    final git = await _pump(tester);
    await _dragOnto(tester, find.text('feature'), find.text('head commit'));
    await tester.tap(find.text('Move feature here'));
    await tester.pumpAndSettle();
    expect(find.text('Move branch feature'), findsOneWidget);
    await tester.tap(find.text('Move branch'));
    await tester.pumpAndSettle();
    expect(git.movedBranches, [('feature', 'aaaaaaa1111111')]);
    expect(git.mergedBranches, isEmpty);
    expect(git.rebasedOnto, isEmpty);
  });
}
