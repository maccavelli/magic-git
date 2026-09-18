// MADR 0051 Phase 7: the pending-op banner and its op→GitService dispatch,
// shared by Status and Branches, and Branches' full-width use of it.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/pending_op_banner.dart';

const _repo = '/repo';
const _ok = SSHCommandResult(exitCode: 0, stdout: '', stderr: '');

/// Records which `--abort` / `--continue` ran.
class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<String> calls = [];

  Future<void> _void(String name) async => calls.add(name);
  Future<SSHCommandResult> _result(String name) async {
    calls.add(name);
    return _ok;
  }

  @override
  Future<void> mergeAbort(String repoPath) => _void('mergeAbort');
  @override
  Future<void> cherryPickAbort(String repoPath) => _void('cherryPickAbort');
  @override
  Future<void> revertAbort(String repoPath) => _void('revertAbort');
  @override
  Future<void> rebaseAbort(String repoPath) => _void('rebaseAbort');
  @override
  Future<void> amAbort(String repoPath) => _void('amAbort');
  @override
  Future<SSHCommandResult> mergeContinue(String repoPath) =>
      _result('mergeContinue');
  @override
  Future<SSHCommandResult> cherryPickContinue(String repoPath) =>
      _result('cherryPickContinue');
  @override
  Future<SSHCommandResult> revertContinue(String repoPath) =>
      _result('revertContinue');
  @override
  Future<SSHCommandResult> rebaseContinue(String repoPath) =>
      _result('rebaseContinue');
  @override
  Future<SSHCommandResult> amContinue(String repoPath) => _result('amContinue');
}

const _expected = {
  PendingOp.merge: (
    'Merge',
    'mergeAbort',
    'git merge --continue',
    'mergeContinue',
  ),
  PendingOp.cherryPick: (
    'Cherry-pick',
    'cherryPickAbort',
    'git cherry-pick --continue',
    'cherryPickContinue',
  ),
  PendingOp.revert: (
    'Revert',
    'revertAbort',
    'git revert --continue',
    'revertContinue',
  ),
  PendingOp.rebase: (
    'Rebase',
    'rebaseAbort',
    'git rebase --continue',
    'rebaseContinue',
  ),
  PendingOp.am: (
    'Patch application',
    'amAbort',
    'git am --continue',
    'amContinue',
  ),
};

Future<void> _pumpApp(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(
    MacosApp(debugShowCheckedModeBanner: false, home: home),
  );
  await tester.pumpAndSettle();
}

/// Branches with a pending op. Mid-rebase HEAD is detached, so no ref is
/// marked current — exactly the case a row-level indicator could not place.
Future<_FakeGit> _pumpBranches(WidgetTester tester, PendingOp op) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      pendingOpProvider(_repo).overrideWith((ref) async => op),
      refsProvider(_repo).overrideWith(
        (ref) async => const [
          GitRef(
            name: 'refs/heads/feature',
            oid: 'f1',
            isHead: false,
            subject: 's',
          ),
          GitRef(
            name: 'refs/heads/main',
            oid: 'm1',
            isHead: false,
            subject: 's',
          ),
        ],
      ),
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
  return git;
}

void main() {
  group('shared dispatch', () {
    test('every op has its verb, its --abort and its --continue', () async {
      for (final MapEntry(key: op, value: e) in _expected.entries) {
        final (verb, abortCall, continueLabel, continueCall) = e;
        expect(pendingOpVerb(op), verb, reason: '$op verb');

        final git = _FakeGit();
        await abortPendingOp(git, _repo, op);
        expect(git.calls, [abortCall], reason: '$op abort');

        final step = continuePendingOp(git, op);
        expect(step, isNotNull, reason: '$op continue');
        final (label, run) = step!;
        expect(label, continueLabel);
        await run(_repo);
        expect(git.calls, [abortCall, continueCall], reason: '$op continue');
      }
    });

    test('PendingOp.none aborts nothing and has no continue', () async {
      final git = _FakeGit();
      await abortPendingOp(git, _repo, PendingOp.none);
      expect(git.calls, isEmpty);
      expect(continuePendingOp(git, PendingOp.none), isNull);
    });
  });

  group('PendingOpBanner', () {
    testWidgets('names the op and wires Continue and Abort', (tester) async {
      var continued = 0;
      var aborted = 0;
      await _pumpApp(
        tester,
        PendingOpBanner(
          op: PendingOp.rebase,
          onContinue: () => continued++,
          onAbort: () => aborted++,
        ),
      );

      expect(find.textContaining('Rebase in progress'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.tap(find.text('Abort Rebase'));
      expect((continued, aborted), (1, 1));
    });

    testWidgets('confirmAbortPendingOp answers the dialog', (tester) async {
      late BuildContext ctx;
      await _pumpApp(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      );

      Future<bool?> answer(String button) async {
        bool? result;
        // Left pending while the test drives the dialog below.
        unawaited(
          confirmAbortPendingOp(ctx, PendingOp.merge).then((v) => result = v),
        );
        await tester.pumpAndSettle();
        expect(find.text('Abort Merge'), findsOneWidget);
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        return result;
      }

      expect(await answer('Abort'), isTrue);
      expect(await answer('Cancel'), isFalse);
    });
  });

  group('Branches shows the banner full-width', () {
    testWidgets('mid-rebase, with no branch marked current', (tester) async {
      final git = await _pumpBranches(tester, PendingOp.rebase);

      expect(find.textContaining('Rebase in progress'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(git.calls, ['rebaseContinue']);
    });

    testWidgets('Abort waits for its confirmation', (tester) async {
      final git = await _pumpBranches(tester, PendingOp.rebase);

      await tester.tap(find.text('Abort Rebase'));
      await tester.pumpAndSettle();
      expect(git.calls, isEmpty, reason: 'nothing before the confirm');

      await tester.tap(find.text('Abort').last);
      await tester.pumpAndSettle();
      expect(git.calls, ['rebaseAbort']);
    });

    testWidgets('cancelling the abort aborts nothing', (tester) async {
      final git = await _pumpBranches(tester, PendingOp.merge);

      await tester.tap(find.text('Abort Merge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(git.calls, isEmpty);
    });

    testWidgets('no pending op, no banner', (tester) async {
      await _pumpBranches(tester, PendingOp.none);

      expect(find.textContaining('in progress'), findsNothing);
      expect(find.text('Continue'), findsNothing);
    });
  });
}
