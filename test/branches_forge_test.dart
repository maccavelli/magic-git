// Phase-2 signal on the Branches tab: the fused forge status (open PR/MR chip,
// CI dot, detail "Open PR"), the grey "merged" badge, pin/unpin into a top
// section, and drag-one-branch-onto-the-current-one to merge or rebase.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
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
import 'package:remote_magic_git/features/common/inline_action_button.dart';
import 'package:remote_magic_git/features/forge/forge_widgets.dart' show CiDot;
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(name: 'refs/heads/feature', oid: 'bbb', isHead: false, subject: 's'),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  String? merged;
  String? rebasedOnto;

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) async {
    merged = branch;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> rebaseOnto(String repoPath, String upstream) async {
    rebasedOnto = upstream;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<_FakeGit> _pump(
  WidgetTester tester, {
  Map<String, BranchForge> forge = const {},
  Set<String> merged = const {},
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => forge),
      mergedBranchesProvider(_repo).overrideWith((ref) async => merged),
      // Clean tree so guardedBranchSwitch/merge run without a confirm in the way.
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
        home: BranchesView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets('an open PR + CI surface as a row chip/dot and a detail Open '
      'button', (tester) async {
    await _pump(
      tester,
      forge: const {
        'feature': BranchForge(
          requestNumber: 5,
          requestUrl: 'https://example.com/pr/5',
          requestTitle: 'Add the feature',
          ci: ForgeCi.success,
          ciUrl: 'https://example.com/ci',
        ),
      },
    );

    // Row: the PR number chip and a CI dot.
    expect(find.text('#5'), findsOneWidget);
    expect(find.byType(CiDot), findsWidgets);

    // Detail: the PR line and an Open button.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(find.text('Pull request'), findsOneWidget);
    expect(find.widgetWithText(InlineActionButton, 'Open #5'), findsOneWidget);
  });

  testWidgets('a branch merged into HEAD shows the grey "merged" badge', (
    tester,
  ) async {
    await _pump(tester, merged: const {'feature'});
    expect(find.text('merged'), findsOneWidget);
  });

  testWidgets('pinning a branch hoists it into a Pinned section', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pump(tester);

    expect(find.text('Pinned (1)'), findsNothing);

    // Right-click feature → Pin to top.
    await tester.tap(
      find.text('feature'),
      buttons: kSecondaryButton,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to top'));
    await tester.pumpAndSettle();

    expect(find.text('Pinned (1)'), findsOneWidget);
  });

  testWidgets(
    'dropping a branch onto the current one offers merge, which runs',
    (tester) async {
      final git = await _pump(tester);

      final from = tester.getCenter(find.text('feature'));
      final to = tester.getCenter(find.text('main'));
      final gesture = await tester.startGesture(from);
      await tester.pump();
      await gesture.moveTo(from + const Offset(12, 0)); // exceed touch slop
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // The merge-vs-rebase choice, phrased explicitly.
      final mergeChoice = find.text('Merge "feature" into "main"');
      expect(mergeChoice, findsOneWidget);
      await tester.tap(mergeChoice);
      await tester.pumpAndSettle();

      expect(git.merged, 'feature');
      expect(git.rebasedOnto, isNull);
    },
  );
}
