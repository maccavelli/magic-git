// Regression coverage for the branches panel's interaction guards:
//
//  * Enter typed into the "New branch name" field must CREATE the branch —
//    it used to bubble to the list's key handler and check out the selected
//    branch instead (the field lives inside the list's Focus scope).
//  * The merge pulldown is disabled while an operation is in flight — its
//    items used to stay live, showing a confirm dialog whose confirmed merge
//    then silently no-opped on runLogged's busy check.
//  * "Delete Local and on <remote>" only pushes the remote delete when the
//    local delete succeeded.
//  * Deleting a branch held by a worktree AND not fully merged requires BOTH
//    confirmations — removing the worktree used to jump straight to a force
//    delete, skipping the unmerged-commits guard.
//  * A repo switch clears the selection — Enter must never act on a
//    same-named branch in the new repo.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';

const _repo = '/repo';
const _repoB = '/repo-b';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(name: 'refs/heads/feature', oid: 'bbb', isHead: false, subject: 's'),
];

class _SpyGit extends GitService {
  _SpyGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> checkouts = [];
  final List<String> created = [];
  final List<(String, bool)> branchDeletes = []; // (name, force)
  final List<String> removedWorktrees = [];
  final List<String> tagDeletes = [];
  final List<String> remoteTagDeletes = [];

  /// Queued failures for [deleteBranch], keyed by call order — a null entry
  /// means that call succeeds.
  final List<GitException?> deleteBranchFailures = [];
  bool failDeleteTag = false;
  final List<(String, String)> upstreamsSet = []; // (branch, upstream)
  int fetches = 0;

  Completer<void>? checkoutGate;

  @override
  Future<void> setUpstream(
    String repoPath,
    String branch,
    String upstream,
  ) async {
    upstreamsSet.add((branch, upstream));
  }

  @override
  Future<SSHCommandResult> fetch(String repoPath) async {
    fetches++;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> checkout(String repoPath, String ref) async {
    checkouts.add(ref);
    final gate = checkoutGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> createBranch(
    String repoPath,
    String name, {
    bool checkout = true,
  }) async {
    created.add(name);
  }

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    branchDeletes.add((name, force));
    final failure = deleteBranchFailures.isNotEmpty
        ? deleteBranchFailures.removeAt(0)
        : null;
    if (failure != null) throw failure;
  }

  @override
  Future<void> removeWorktree(
    String repoPath,
    String path, {
    bool force = false,
    bool locked = false,
  }) async {
    removedWorktrees.add(path);
  }

  @override
  Future<void> deleteTag(String repoPath, String name) async {
    tagDeletes.add(name);
    if (failDeleteTag) {
      throw const GitException(
        'git tag -d failed',
        SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );
    }
  }

  @override
  Future<SSHCommandResult> deleteRemoteTag(
    String repoPath,
    String remote,
    String name,
  ) async {
    remoteTagDeletes.add('$remote/$name');
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

const _heldByWorktree = GitException(
  'git branch -d failed',
  SSHCommandResult(
    exitCode: 1,
    stdout: '',
    stderr: "error: cannot delete branch 'held' used by worktree at '/wt/held'",
  ),
);

const _notFullyMerged = GitException(
  'git branch -d failed',
  SSHCommandResult(
    exitCode: 1,
    stdout: '',
    stderr: "error: the branch 'held' is not fully merged.",
  ),
);

Future<_SpyGit> _pump(
  WidgetTester tester, {
  List<GitRef> refs = _refs,
  List<GitRef> refsB = _refs,
  Map<String, String>? remoteTags,
  String repoPath = _repo,
}) async {
  final git = _SpyGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => refs),
      refsProvider(_repoB).overrideWith((ref) async => refsB),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remotesProvider(_repoB).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => remoteTags),
      remoteTagsProvider(_repoB).overrideWith((ref) async => remoteTags),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(branch: const GitBranchInfo(), files: const []),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: BranchesView(repoPath: repoPath),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

Finder _selectedRows() => find.byWidgetPredicate(
  (w) => w is Container && w.color == AppTheme.rowSelectionTint,
);

/// The create-branch field specifically — the filter bar is also a
/// MacosTextField and sits above it in the tree.
Finder _newBranchField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'New branch name',
);

void main() {
  testWidgets('Enter in the New-branch field creates the branch and never '
      'checks out the selected one', (tester) async {
    final git = await _pump(tester);

    // Select a branch, exactly the state the old bug needed.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    await tester.enterText(_newBranchField(), 'my-new-branch');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(git.checkouts, isEmpty,
        reason: 'Enter in the field must not bubble into a checkout');
    expect(git.created, ['my-new-branch']);
  });

  testWidgets('Enter pressed as a raw key in the field also does not check '
      'out (focus-guarded key handler)', (tester) async {
    final git = await _pump(tester);
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    await tester.tap(_newBranchField());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(git.checkouts, isEmpty);
  });

  testWidgets('the merge pulldown is disabled while an operation is in '
      'flight', (tester) async {
    final git = await _pump(tester);
    git.checkoutGate = Completer<void>();

    // Start a gated checkout — the panel is now busy.
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is MacosIcon && w.icon == CupertinoIcons.square_arrow_down,
          )
          .first,
    );
    await tester.pump();

    final pulldown = tester.widget<MacosPulldownButton>(
      find.byType(MacosPulldownButton).first,
    );
    expect(pulldown.items, isNull,
        reason: 'null items = disabled, like every sibling button');

    git.checkoutGate!.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MacosPulldownButton>(find.byType(MacosPulldownButton).first)
          .items,
      isNotNull,
      reason: 're-enabled once the operation completes',
    );
  });

  testWidgets('a failed local tag delete stops the remote half of "Delete '
      'Local and on origin"', (tester) async {
    const tagRefs = [
      ..._refs,
      GitRef(name: 'refs/tags/v1', oid: 'ttt', isHead: false, subject: 's'),
    ];
    final git = await _pump(
      tester,
      refs: tagRefs,
      remoteTags: const {'v1': 'ttt'}, // known on the remote → 3-way dialog
    );
    git.failDeleteTag = true;

    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
          )
          .last,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Delete Local and on origin'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The local failure surfaced an error dialog — dismiss it.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(git.tagDeletes, ['v1']);
    expect(git.remoteTagDeletes, isEmpty,
        reason: 'the remote delete must be gated on local success');
  });

  testWidgets('deleting a worktree-held AND unmerged branch requires the '
      'unmerged confirmation after the worktree removal', (tester) async {
    const heldRefs = [
      GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
      GitRef(
        name: 'refs/heads/held',
        oid: 'bbb',
        isHead: false,
        subject: 's',
        worktreePath: '/wt/held',
      ),
    ];
    final git = await _pump(tester, refs: heldRefs);
    git.deleteBranchFailures.addAll([_heldByWorktree, _notFullyMerged, null]);

    // The held branch's row hides the plain delete button, so drive the
    // ⌘⌫ path: select the row, then invoke the panel's delete binding
    // directly (SingleActivator has no ==, so match by fields — same
    // technique as keyboard_shortcuts_test).
    // `.first`: the row's worktree badge chip also renders "held".
    await tester.tap(find.text('held').first);
    await tester.pumpAndSettle();
    VoidCallback? deleteBinding;
    for (final element in find.byType(PanelShortcuts).evaluate()) {
      final bindings = (element.widget as PanelShortcuts).bindings;
      for (final entry in bindings.entries) {
        final a = entry.key;
        if (a is SingleActivator &&
            a.trigger == LogicalKeyboardKey.backspace &&
            a.meta) {
          deleteBinding = entry.value;
        }
      }
    }
    expect(deleteBinding, isNotNull);
    deleteBinding!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Confirm the plain delete…
    await tester.tap(find.text('Delete').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // …it fails as held-by-worktree; confirm removing the worktree too.
    expect(find.text('Branch is checked out in a worktree'), findsOneWidget);
    await tester.tap(find.text('Remove Worktree and Delete'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The retry is a PLAIN delete that now fails as unmerged — the force
    // decision gets its own confirmation instead of being assumed.
    expect(git.removedWorktrees, ['/wt/held']);
    expect(find.text('Branch not fully merged'), findsOneWidget);
    await tester.tap(find.text('Force Delete'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(git.branchDeletes, [
      ('held', false),
      ('held', false),
      ('held', true),
    ]);
  });

  testWidgets('the current branch row offers Set upstream via its own menu',
      (tester) async {
    final git = await _pump(tester);

    // The head row's ellipsis menu is the first pulldown (main sorts first).
    await tester.tap(find.byType(MacosPulldownButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set upstream…'));
    await tester.pumpAndSettle();

    // The prompt pre-fills origin/<branch>; confirm as-is.
    await tester.tap(find.text('Set Upstream'));
    await tester.pumpAndSettle();

    expect(git.upstreamsSet, [('main', 'origin/main')]);
  });

  testWidgets('the Remote Branches header fetch-and-prune button runs fetch',
      (tester) async {
    final git = await _pump(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is MacosIcon && w.icon == CupertinoIcons.arrow_2_circlepath,
      ),
    );
    await tester.pumpAndSettle();
    expect(git.fetches, 1);
  });

  testWidgets('a repo switch clears the branch selection', (tester) async {
    final git = _SpyGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => _refs),
        refsProvider(_repoB).overrideWith((ref) async => _refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remotesProvider(_repoB).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        remoteTagsProvider(_repoB).overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);

    Widget shell(String repoPath) => UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: BranchesView(repoPath: repoPath),
      ),
    );

    await tester.pumpWidget(shell(_repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(_selectedRows(), findsOneWidget);

    // Same State, new repoPath — exactly what the unkeyed panel does.
    await tester.pumpWidget(shell(_repoB));
    await tester.pumpAndSettle();
    expect(_selectedRows(), findsNothing,
        reason: 'a selection must never survive into another repo');
  });
}
