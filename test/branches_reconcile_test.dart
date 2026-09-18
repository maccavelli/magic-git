// MADR 0051 Phase 5: the Reconcile action for a diverged current branch —
// where it is offered, and that each choice reaches the right GitService call.

import 'package:flutter/cupertino.dart' show Size;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';
const _ok = SSHCommandResult(exitCode: 0, stdout: '', stderr: '');

const _divergedHead = GitRef(
  name: 'refs/heads/main',
  oid: 'h1',
  isHead: true,
  subject: 's',
  upstream: 'origin/main',
  ahead: 2,
  behind: 1,
);
const _upToDateHead = GitRef(
  name: 'refs/heads/main',
  oid: 'h1',
  isHead: true,
  subject: 's',
  upstream: 'origin/main',
);
const _mainRemote = GitRef(
  name: 'refs/remotes/origin/main',
  oid: 'r1',
  isHead: false,
  subject: 's',
);
const _divergedFeature = GitRef(
  name: 'refs/heads/feature',
  oid: 'f1',
  isHead: false,
  subject: 's',
  upstream: 'origin/feature',
  ahead: 1,
  behind: 3,
);
const _featureRemote = GitRef(
  name: 'refs/remotes/origin/feature',
  oid: 'r2',
  isHead: false,
  subject: 's',
);

class _FakeGit extends GitService {
  _FakeGit({this.commonAncestor = true})
    : super(SSHCommandExecutor(SSHClientManager()));

  final bool commonAncestor;
  final List<(String, MergeMode, bool)> merges = [];
  final List<String> rebases = [];
  final List<(String, ResetMode)> resets = [];

  @override
  Future<bool> haveCommonAncestor(String repoPath, String a, String b) async =>
      commonAncestor;

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
    bool allowUnrelatedHistories = false,
  }) async {
    merges.add((branch, mode, allowUnrelatedHistories));
    return _ok;
  }

  @override
  Future<SSHCommandResult> rebaseOnto(String repoPath, String upstream) async {
    rebases.add(upstream);
    return _ok;
  }

  @override
  Future<void> reset(
    String repoPath,
    String hash, {
    required ResetMode mode,
  }) async {
    resets.add((hash, mode));
  }
}

Future<void> _pump(WidgetTester tester, List<GitRef> refs, _FakeGit git) async {
  // The Advanced pulldown is taller than the default 800x600 canvas allows
  // at the row's position (see branches_actions_test.dart).
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
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
}

Future<void> _rightClick(WidgetTester tester, String row) async {
  await tester.tap(
    find.text(row).first,
    buttons: kSecondaryButton,
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
}

Future<void> _openAdvanced(WidgetTester tester, String row) async {
  await tester.tap(find.text(row).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Advanced'));
  await tester.pumpAndSettle();
}

Future<void> _dismiss(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

/// Right-click the current branch → Reconcile…, leaving the chooser open.
Future<void> _openReconcile(WidgetTester tester) async {
  await _rightClick(tester, 'main');
  await tester.tap(find.text('Reconcile…'));
  await tester.pumpAndSettle();
}

void main() {
  group('Reconcile is offered', () {
    testWidgets('on a diverged current branch, in both menus', (tester) async {
      await _pump(tester, const [_divergedHead, _mainRemote], _FakeGit());

      await _rightClick(tester, 'main');
      expect(find.text('Reconcile…'), findsOneWidget, reason: 'context menu');
      await _dismiss(tester);

      await _openAdvanced(tester, 'main');
      expect(find.text('Reconcile…'), findsOneWidget, reason: 'Advanced menu');
      await _dismiss(tester);
    });

    testWidgets('not on a diverged branch that is not checked out', (
      tester,
    ) async {
      await _pump(tester, const [
        _upToDateHead,
        _mainRemote,
        _divergedFeature,
        _featureRemote,
      ], _FakeGit());

      await _rightClick(tester, 'feature');
      expect(find.text('Reconcile…'), findsNothing, reason: 'context menu');
      await _dismiss(tester);

      await _openAdvanced(tester, 'feature');
      expect(find.text('Reconcile…'), findsNothing, reason: 'Advanced menu');
      await _dismiss(tester);
    });

    testWidgets('not on an up-to-date current branch', (tester) async {
      await _pump(tester, const [_upToDateHead, _mainRemote], _FakeGit());

      await _rightClick(tester, 'main');
      expect(find.text('Reconcile…'), findsNothing, reason: 'context menu');
      await _dismiss(tester);

      await _openAdvanced(tester, 'main');
      expect(find.text('Reconcile…'), findsNothing, reason: 'Advanced menu');
      await _dismiss(tester);
    });
  });

  group('each Reconcile choice reaches the right call', () {
    testWidgets('Merge merges the upstream into the current branch', (
      tester,
    ) async {
      final git = _FakeGit();
      await _pump(tester, const [_divergedHead, _mainRemote], git);

      await _openReconcile(tester);
      await tester.tap(find.text('Merge "origin/main" into "main"'));
      await tester.pumpAndSettle();

      expect(git.merges, [('origin/main', MergeMode.normal, false)]);
      expect(git.rebases, isEmpty);
      expect(git.resets, isEmpty);
    });

    testWidgets('Rebase rebases the current branch onto the upstream', (
      tester,
    ) async {
      final git = _FakeGit();
      await _pump(tester, const [_divergedHead, _mainRemote], git);

      await _openReconcile(tester);
      await tester.tap(find.text('Rebase "main" onto "origin/main"'));
      await tester.pumpAndSettle();

      expect(git.rebases, ['origin/main']);
      expect(git.merges, isEmpty);
      expect(git.resets, isEmpty);
    });

    testWidgets('Reset waits for its own confirmation, then hard-resets', (
      tester,
    ) async {
      final git = _FakeGit();
      await _pump(tester, const [_divergedHead, _mainRemote], git);

      await _openReconcile(tester);
      await tester.tap(find.text('Reset "main" to "origin/main"'));
      await tester.pumpAndSettle();

      expect(git.resets, isEmpty, reason: 'nothing before the confirm');
      expect(find.text('Reset to origin/main?'), findsOneWidget);
      expect(find.textContaining('discards 2 commits'), findsOneWidget);

      await tester.tap(find.text('Reset').last);
      await tester.pumpAndSettle();

      expect(git.resets, [('origin/main', ResetMode.hard)]);
    });

    testWidgets('cancelling Reset\'s confirmation resets nothing', (
      tester,
    ) async {
      final git = _FakeGit();
      await _pump(tester, const [_divergedHead, _mainRemote], git);

      await _openReconcile(tester);
      await tester.tap(find.text('Reset "main" to "origin/main"'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      expect(git.resets, isEmpty);
    });

    testWidgets('Cancel in the chooser does nothing', (tester) async {
      final git = _FakeGit();
      await _pump(tester, const [_divergedHead, _mainRemote], git);

      await _openReconcile(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(git.merges, isEmpty);
      expect(git.rebases, isEmpty);
      expect(git.resets, isEmpty);
    });

    testWidgets('unrelated histories skip the chooser for the explicit '
        'allow-unrelated merge', (tester) async {
      final git = _FakeGit(commonAncestor: false);
      await _pump(tester, const [_divergedHead, _mainRemote], git);

      await _openReconcile(tester);

      expect(find.text('Reconcile with origin/main'), findsNothing);
      expect(find.text('Merge unrelated histories'), findsOneWidget);
      await tester.tap(find.text('Merge Anyway'));
      await tester.pumpAndSettle();

      expect(git.merges, [('origin/main', MergeMode.normal, true)]);
      expect(git.rebases, isEmpty);
      expect(git.resets, isEmpty);
    });
  });
}
