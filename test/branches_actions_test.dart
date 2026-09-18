// The Branches panel's newer affordances: upstream-divergence badges, rename,
// delete-on-remote, and the fast-forward-only merge item.

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

const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: 'aaa',
    isHead: true,
    upstream: 'origin/main',
    subject: 's',
    ahead: 2,
    behind: 1,
  ),
  GitRef(
    name: 'refs/heads/stale',
    oid: 'bbb',
    isHead: false,
    upstream: 'origin/stale',
    subject: 's',
    upstreamGone: true,
  ),
  GitRef(
    name: 'refs/remotes/origin/feature',
    oid: 'ccc',
    isHead: false,
    subject: 's',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<(String, String)> renames = [];
  final List<(String, String)> remoteDeletes = [];
  final List<MergeMode> merges = [];
  final List<(String, String)> upstreamsSet = [];

  @override
  Future<void> setUpstream(
    String repoPath,
    String branch,
    String upstream,
  ) async {
    upstreamsSet.add((branch, upstream));
  }

  @override
  Future<void> renameBranch(
    String repoPath,
    String oldName,
    String newName,
  ) async {
    renames.add((oldName, newName));
  }

  @override
  Future<SSHCommandResult> deleteRemoteBranch(
    String repoPath,
    String remote,
    String branch, {
    CommandOutputCallback? onOutput,
  }) async {
    remoteDeletes.add((remote, branch));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) async {
    merges.add(mode);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<_FakeGit> _pump(WidgetTester tester) async {
  // The Advanced pulldown now carries enough items (merge modes, upstream,
  // rename, pin, copy, delete) that macos_ui's default positioning can
  // overflow the harness's default 800x600 canvas and assert rather than
  // clamp — branches_worktree_badge_test.dart hit the same limit first.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      // The view now watches CONFIGURED remotes to pick the tag-push target
      // — unoverridden it would fall through to the executor.
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      // The real provider keeps a five-minute keepAlive timer that widget
      // tests would flag as still pending; null = unknown, no badges.
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

// Row actions live on a right-click context menu now.
Future<void> _rightClick(WidgetTester tester, Finder f) =>
    tester.tap(f, buttons: kSecondaryButton, warnIfMissed: false);

void main() {
  testWidgets('divergence badges: ↑/↓ for a diverged branch, "gone" for a '
      'deleted upstream', (tester) async {
    await _pump(tester);

    expect(find.text('↑2 ↓1'), findsOneWidget);
    expect(find.text('gone'), findsOneWidget);
  });

  testWidgets('rename prompts with the current name and calls the service', (
    tester,
  ) async {
    final git = await _pump(tester);

    // The current branch is renameable too — right-click it → Rename….
    await _rightClick(tester, find.text('main'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();

    // Pre-filled with the old name; replace and confirm.
    await tester.enterText(find.byType(MacosTextField).last, 'trunk');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(git.renames, [('main', 'trunk')]);
  });

  testWidgets('deleting a remote branch confirms, then pushes the delete', (
    tester,
  ) async {
    final git = await _pump(tester);

    // Right-click the remote branch → Delete branch on the remote.
    await _rightClick(tester, find.text('origin/feature'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete branch on the remote'));
    await tester.pumpAndSettle();

    expect(git.remoteDeletes, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Delete on Remote'));
    await tester.pumpAndSettle();

    expect(git.remoteDeletes, [('origin', 'feature')]);
  });

  testWidgets('the merge menu offers fast-forward only', (tester) async {
    final git = await _pump(tester);

    // Right-click the non-current local branch → its merge modes.
    await _rightClick(tester, find.text('stale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge (fast-forward only)'));
    await tester.pumpAndSettle();
    // Through the confirm dialog the merge flow shows.
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();

    expect(git.merges, [MergeMode.ffOnly]);
  });

  testWidgets('Set upstream refuses a target with no matching remote-tracking '
      'branch, naming Publish instead', (tester) async {
    final git = await _pump(tester);

    // "main"'s default target (origin/main) has no matching entry in the
    // fixture's ref list — only origin/feature exists as a remote branch.
    await _rightClick(tester, find.text('main'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set upstream…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No remote-tracking branch'), findsOneWidget);
    expect(find.textContaining('use Publish instead'), findsOneWidget);

    // The confirm button is disabled while the problem stands — nothing
    // reaches the service.
    await tester.tap(find.text('Set Upstream'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(git.upstreamsSet, isEmpty);
  });

  testWidgets(
    'Set upstream accepts a target that matches a real remote-tracking '
    'branch',
    (tester) async {
      final git = await _pump(tester);

      await _rightClick(tester, find.text('main'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set upstream…'));
      await tester.pumpAndSettle();

      final field = find.byType(MacosTextField).last;
      await tester.enterText(field, 'origin/feature');
      await tester.pumpAndSettle();
      expect(find.textContaining('No remote-tracking branch'), findsNothing);

      await tester.tap(find.text('Set Upstream'));
      await tester.pumpAndSettle();

      expect(git.upstreamsSet, [('main', 'origin/feature')]);
    },
  );

  testWidgets(
    'the Advanced menu offers every row action the context menu does, for '
    'the same non-head branch',
    (tester) async {
      // "stale": non-head, upstream set (so both Merge-mode items and Unset
      // upstream appear in both menus). Forge-workflow items (Create Pull/
      // Merge Request, Open on Forge, Open reachable history) are
      // deliberately excluded from this comparison — the context menu has
      // no forge-workflow concept at all, by design, not by omission; MADR
      // 0051 named the merge/upstream/rename/pin/copy/delete set as the
      // parity gap, not forge actions.
      const sharedRowActions = [
        'Check out',
        'Check out in a new worktree…',
        'Merge into current',
        'Merge (no fast-forward)',
        'Merge (fast-forward only)',
        'Squash merge',
        'Set upstream…',
        'Unset upstream',
        'Rename…',
        'Pin to top',
        'Copy name',
        'Delete branch',
      ];

      await _pump(tester);
      await _rightClick(tester, find.text('stale'));
      await tester.pumpAndSettle();
      for (final label in sharedRowActions) {
        expect(
          find.text(label),
          findsAtLeastNWidgets(1),
          reason: 'context menu missing "$label"',
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.text('stale'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      for (final label in sharedRowActions) {
        expect(
          find.text(label),
          findsAtLeastNWidgets(1),
          reason: 'Advanced menu missing "$label"',
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );
}
