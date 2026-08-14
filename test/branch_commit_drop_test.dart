// E2: drag a commit onto a branch row to cherry-pick onto that branch.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';

const _repo = '/repo';

const _commit = GitCommit(
  hash: 'ccccccc3333333',
  shortHash: 'ccccccc',
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-08-13T10:00',
  parents: [],
  subject: 'picked commit',
);

const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: 'aaa',
    isHead: true,
    subject: 'head commit',
  ),
  GitRef(
    name: 'refs/heads/feature',
    oid: 'bbb',
    isHead: false,
    subject: 'feature commit',
  ),
];

class _PickFakeGit extends GitService {
  _PickFakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  final checkouts = <String>[];
  final picks = <(String, int?)>[];

  @override
  Future<void> checkout(String repoPath, String ref) async {
    checkouts.add(ref);
  }

  @override
  Future<SSHCommandResult> cherryPick(
    String repoPath,
    String hash, {
    int? mainline,
  }) async {
    picks.add((hash, mainline));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<_PickFakeGit> _pump(WidgetTester tester) async {
  final git = _PickFakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(
        _repo,
      ).overrideWith((ref) async => const <String, BranchForge>{}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
      statusProvider(_repo).overrideWith(
        (ref) async =>
            GitStatus(branch: const GitBranchInfo(), files: const []),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: Column(
          children: [
            SizedBox(
              height: 40,
              child: DragItemDraggable(
                item: DragCommit(_commit),
                immediate: true,
                child: Text('drag-commit'),
              ),
            ),
            Expanded(child: BranchesView(repoPath: _repo)),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

Future<void> _dragOnto(WidgetTester tester, Finder chip, Finder target) async {
  final from = tester.getCenter(chip);
  final to = tester.getCenter(target);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'dropping a commit on a non-current branch confirms, checks out, then picks',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final git = await _pump(tester);

      await _dragOnto(tester, find.text('drag-commit'), find.text('feature'));
      expect(find.text('Cherry-pick onto feature'), findsOneWidget);
      await tester.tap(find.text('Cherry-pick'));
      await tester.pumpAndSettle();

      expect(git.checkouts, ['feature']);
      expect(git.picks, [(_commit.hash, null)]);
    },
  );

  testWidgets(
    'dropping a commit on the current branch cherry-picks without checkout',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final git = await _pump(tester);

      await _dragOnto(tester, find.text('drag-commit'), find.text('main'));
      expect(find.text('Cherry-pick onto main'), findsOneWidget);
      await tester.tap(find.text('Cherry-pick'));
      await tester.pumpAndSettle();

      expect(git.checkouts, isEmpty);
      expect(git.picks, [(_commit.hash, null)]);
    },
  );
}
