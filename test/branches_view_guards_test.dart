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
//  * The Review-mode batch bar (Pin/Unpin/Hide/Delete if merged…) — see
//    [_selectTwoInReview] for why Review mode is load-bearing here.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branch_workspace_prefs.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _rightClick(WidgetTester tester, Finder f) =>
    tester.tap(f, buttons: kSecondaryButton, warnIfMissed: false);

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
  final List<bool> removeWorktreeForce = []; // force flag per recorded removal
  /// When set, a NON-force [removeWorktree] throws this (git's dirty/locked
  /// refusal); the `--force` retry still succeeds.
  GitException? worktreeRemoveNonForceFailure;
  final List<String> tagDeletes = [];
  final List<String> remoteTagDeletes = [];

  /// Queued failures for [deleteBranch], keyed by call order — a null entry
  /// means that call succeeds.
  final List<GitException?> deleteBranchFailures = [];
  bool failDeleteTag = false;
  final List<(String, String)> upstreamsSet = []; // (branch, upstream)
  int fetches = 0;

  Completer<void>? checkoutGate;

  /// The bulk-delete sheet's mutation. Stubbed so the sheet can actually RUN a
  /// delete — without it the sheet only ever returns null on Cancel, and the
  /// `if (results != null)` branch under test is never reached.
  final List<String> baseDeletes = [];

  @override
  Future<BaseDeleteResult> deleteBranchMergedIntoBase(
    String repoPath, {
    required String branchName,
    required String expectedBranchOid,
    required String baseOid,
  }) async {
    baseDeletes.add(branchName);
    return BaseDeleteResult(
      branchName: branchName,
      status: BaseDeleteStatus.deleted,
      deletedOid: expectedBranchOid,
    );
  }

  @override
  Future<void> setUpstream(
    String repoPath,
    String branch,
    String upstream,
  ) async {
    upstreamsSet.add((branch, upstream));
  }

  @override
  Future<SSHCommandResult> fetch(
    String repoPath, {
    bool background = false,
    FetchScope scope = FetchScope.allRemotes,
    CommandOutputCallback? onOutput,
    OperationId? operationId,
    String? upstreamRemote,
  }) async {
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
  Future<void> branchFrom(
    String repoPath,
    String name,
    String startPoint, {
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
    if (!force && worktreeRemoveNonForceFailure != null) {
      throw worktreeRemoveNonForceFailure!;
    }
    removedWorktrees.add(path);
    removeWorktreeForce.add(force);
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
    String name, {
    CommandOutputCallback? onOutput,
  }) async {
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

const _worktreeDirty = GitException(
  'git worktree remove failed',
  SSHCommandResult(
    exitCode: 1,
    stdout: '',
    stderr:
        "fatal: '/wt/held' contains modified or untracked files, use --force "
        'to delete it',
  ),
);

const _heldRefs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/held',
    oid: 'bbb',
    isHead: false,
    subject: 's',
    worktreePath: '/wt/held',
  ),
];

/// Selects the held row and fires the panel's ⌘⌫ delete binding — the held
/// row hides the inline delete button, so the shortcut is the only entry
/// point. Shared by the worktree-delete tests.
Future<void> _invokeDeleteHeld(WidgetTester tester) async {
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
  await _openMoreMenu(tester);
  await tester.tap(find.text('Delete').last); // confirm the plain delete
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<_SpyGit> _pump(
  WidgetTester tester, {
  List<GitRef> refs = _refs,
  List<GitRef> refsB = _refs,
  Map<String, String>? remoteTags,
  String repoPath = _repo,
  List<Override> extraOverrides = const [],

  /// Lets a test dispose the panel while leaving `MacosApp` — and therefore
  /// the root navigator, and anything pushed onto it — mounted. Needed for any
  /// defect whose await is a sheet: replacing the whole tree would take the
  /// sheet down with the panel and prove nothing.
  ValueListenable<bool>? panelVisible,
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
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
      remoteTagsProvider(_repoB).overrideWith((ref) async => remoteTags),
      branchForgeProvider(_repoB).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repoB,
      ).overrideWith((ref) async => const <String>{}),
      statusProvider(_repo).overrideWith(
        (ref) async =>
            GitStatus(branch: const GitBranchInfo(), files: const []),
      ),
      // Appended, not merged: Riverpod THROWS on a duplicate override of
      // the same provider in one container, so these must name providers
      // the defaults above do not.
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: panelVisible == null
            ? BranchesView(repoPath: repoPath)
            : ValueListenableBuilder<bool>(
                valueListenable: panelVisible,
                builder: (_, visible, _) => visible
                    ? BranchesView(repoPath: repoPath)
                    : const Center(child: Text('panel gone')),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

Finder _selectedRows() => find.byWidgetPredicate(
  (w) => w is Container && w.color == AppTheme.rowSelectionTint,
);

/// The compact filter field in the navigator toolbar.
Finder _filterField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Filter branches and tags',
);

Future<void> _openMoreMenu(WidgetTester tester) async {
  // Delete (and other overflow actions) live under the More pulldown.
  if (find.text('Delete').evaluate().isEmpty &&
      find.text('More').evaluate().isNotEmpty) {
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
  }
}

/// The identity the batch fixture writes prefs under. `ssh` is durable, which
/// is what makes `loadBranchWorkspacePrefs` actually see the write — an ad-hoc
/// identity short-circuits (`branch_workspace_prefs.dart:174`).
RepositoryUiIdentity _batchIdentity() =>
    RepositoryUiIdentity.ssh(connectionId: 'c1', gitCommonDir: '/repo/.git');

/// [_pump] plus everything a *persisting* batch action needs: a mocked
/// SharedPreferences and a durable UI identity. Returns the identity so a test
/// can read the prefs back.
Future<RepositoryUiIdentity> _pumpBatch(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],

  /// Supplies the UI identity instead of resolving it immediately — pass a
  /// `Completer.future` to hold `_updateWorkspacePrefs` open while the test
  /// disposes the panel. A parameter rather than an extra override, because
  /// Riverpod rejects overriding the same provider twice in one container.
  Future<RepositoryUiIdentity?>? identityFuture,
  ValueListenable<bool>? panelVisible,
  List<GitRef> refs = _refs,
}) async {
  SharedPreferences.setMockInitialValues({});
  final identity = _batchIdentity();
  await _pump(
    tester,
    refs: refs,
    panelVisible: panelVisible,
    extraOverrides: [
      repositoryUiIdentityProvider(
        _repo,
      ).overrideWith((ref) => identityFuture ?? Future.value(identity)),
      ...extraOverrides,
    ],
  );
  return identity;
}

/// Puts the panel in Review mode and shift-extends the selection to two rows,
/// leaving the batch bar on screen.
///
/// **Review mode is not optional here.** `branch_navigator.dart:450` gates
/// multi-selection on `mode == BranchWorkspaceMode.review`; in `browse` — the
/// default whenever `workspacePrefs.lastMode` is unset, which is every fixture
/// — `onMultiSelect` is never called and both shift-arrow and command-click
/// fall through to ordinary single selection, silently. That is the documented
/// design (MADR 0003, "Review rows and multi-selection"), not a bug, and it is
/// invisible from the test side: the symptoms look like broken modifier
/// synthesis or a focus problem, and both of those were measured working before
/// the real cause was found (MADR 0035).
Future<void> _selectTwoInReview(WidgetTester tester) async {
  await tester.tap(find.text('Review'));
  await tester.pumpAndSettle();
  // Anchor on `feature`, not `main`: once a comparison base is configured the
  // header also renders "main" ("Compared with main"), and `find.text('main')`
  // then matches two widgets and `tap` refuses. `feature` names only its row.
  await tester.tap(find.text('feature'));
  await tester.pumpAndSettle();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
  // The helper checks its own postcondition: a silent fall-through to single
  // selection is exactly the failure mode this file exists to prevent, and it
  // would otherwise surface as a confusing assertion in the caller.
  expect(_batchBarLabels(), [
    'Pin',
    'Unpin',
    'Hide',
    'Delete if merged…',
  ], reason: 'two rows must be selected and the batch bar showing');
}

/// The batch bar's action labels, in render order.
List<String> _batchBarLabels() => [
  for (final e in find.byType(InlineActionButton).evaluate())
    (e.widget as InlineActionButton).label,
];

/// The overrides that give the panel a comparison base and a review batch.
///
/// Without these the "Delete if merged…" button is **disabled** —
/// `busy || base == null` (`branches_view.dart:682`) — which is why MADR 0035's
/// probe could not exercise it: tapping a disabled button is a silent no-op
/// that looks like a passing test.
///
/// Note the interaction with [_batchHide]: with `main` as the base it is
/// skipped for TWO reasons, HEAD *and* comparison base
/// (`branches_view.dart:727,741`), so a Hide assertion under this fixture is
/// not evidence about the HEAD rule on its own.
List<Override> _withBase() => [
  branchBaseProvider.overrideWith(
    (ref, key) async => const BranchBaseResolution(
      base: BranchBase(
        refName: 'refs/heads/main',
        displayName: 'main',
        oid: _mainOid,
        source: BranchBaseSource.localMain,
        isFallback: false,
      ),
    ),
  ),
  branchReviewProvider.overrideWith(
    (ref, key) async => const BranchReviewBatchResult(
      summariesByRefName: {
        'refs/heads/feature': BranchReviewSummary(
          refName: 'refs/heads/feature',
          shortName: 'feature',
          branchOid: _featOid,
          baseOid: _mainOid,
          aheadOfBase: 0,
          behindBase: 0,
        ),
      },
    ),
  ),
];

const _mainOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _featOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// [_refs] with FULL object ids. The bulk-delete sheet is OID-pinned, so a
/// short oid lands every candidate in "Skipped — incomplete OID" and the
/// Delete button stays at "Delete 0". The default `_refs` uses 'aaa'/'bbb',
/// which is right for every other test in this file and useless for this one.
const _refsFullOid = [
  GitRef(name: 'refs/heads/main', oid: _mainOid, isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/feature',
    oid: _featOid,
    isHead: false,
    subject: 's',
  ),
];

void main() {
  testWidgets('creating a branch via the prompt never checks out the '
      'selected one', (tester) async {
    final git = await _pump(tester);

    // Select a branch, then open the New-branch prompt from the Local header.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.add,
      ),
    );
    await tester.pumpAndSettle();

    // Name field in the New branch sheet (not the list filter behind it).
    final nameField = find.byWidgetPredicate(
      (w) => w is MacosTextField && w.placeholder == 'feature/my-work',
    );
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'my-new-branch');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    // Location chooser: Here vs New worktree — stay in this worktree.
    if (find.text('Here').evaluate().isNotEmpty) {
      await tester.tap(find.text('Here'));
      await tester.pumpAndSettle();
    }

    // createBranch/branchFrom may still checkout the *new* branch (not the
    // previously selected one). The regression is that the selection is not
    // checked out as a side effect of the prompt.
    expect(git.checkouts, isEmpty);
    expect(git.created, ['my-new-branch']);
  });

  testWidgets('Enter typed into the filter field does not check out the '
      'selection (focus-guarded key handler)', (tester) async {
    final git = await _pump(tester);
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    await tester.tap(_filterField());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(git.checkouts, isEmpty);
  });

  testWidgets('detail actions are disabled while an operation is in flight', (
    tester,
  ) async {
    final git = await _pump(tester);
    git.checkoutGate = Completer<void>();

    // Select a non-current branch; Check out is primary and busy-gated.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    InlineActionButton checkoutBtn() => tester.widget<InlineActionButton>(
      find.byWidgetPredicate(
        (w) => w is InlineActionButton && w.label == 'Check out',
      ),
    );
    expect(checkoutBtn().onPressed, isNotNull);

    // Start a gated checkout — the panel is now busy.
    await tester.tap(find.text('Check out'));
    await tester.pump();
    expect(
      checkoutBtn().onPressed,
      isNull,
      reason: 'every action goes inert while an op is in flight',
    );

    git.checkoutGate!.complete();
    await tester.pumpAndSettle();
    expect(
      checkoutBtn().onPressed,
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

    await _rightClick(tester, find.text('v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete tag'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Delete Local and on origin'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The local failure surfaced an error dialog — dismiss it.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(git.tagDeletes, ['v1']);
    expect(
      git.remoteTagDeletes,
      isEmpty,
      reason: 'the remote delete must be gated on local success',
    );
  });

  testWidgets('deleting a worktree-held AND unmerged branch requires the '
      'unmerged confirmation after the worktree removal', (tester) async {
    final git = await _pump(tester, refs: _heldRefs);
    git.deleteBranchFailures.addAll([_heldByWorktree, _notFullyMerged, null]);

    await _invokeDeleteHeld(tester);

    // It fails as held-by-worktree; confirm removing the worktree too.
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
    // The worktree removal was NON-force (clean worktree) — no silent discard.
    expect(git.removeWorktreeForce, [false]);
  });

  testWidgets('a dirty worktree prompts before discarding, and declining '
      'leaves the worktree and branch intact', (tester) async {
    final git = await _pump(tester, refs: _heldRefs);
    git.deleteBranchFailures.add(_heldByWorktree);
    git.worktreeRemoveNonForceFailure = _worktreeDirty;

    await _invokeDeleteHeld(tester);

    // Held-by-worktree → confirm removing the worktree too.
    expect(find.text('Branch is checked out in a worktree'), findsOneWidget);
    await tester.tap(find.text('Remove Worktree and Delete'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The non-force removal is refused (dirty) → a SPECIFIC discard confirm,
    // not a silent force. Decline it.
    expect(find.text('Worktree has uncommitted changes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Nothing was force-removed and no force delete ran: work is intact.
    expect(git.removedWorktrees, isEmpty);
    expect(git.branchDeletes, [('held', false)]);
  });

  testWidgets('a dirty worktree, once the discard is confirmed, force-removes '
      'then deletes the branch', (tester) async {
    final git = await _pump(tester, refs: _heldRefs);
    git.deleteBranchFailures.addAll([_heldByWorktree, null]);
    git.worktreeRemoveNonForceFailure = _worktreeDirty;

    await _invokeDeleteHeld(tester);
    await tester.tap(find.text('Remove Worktree and Delete'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Confirm the discard this time.
    expect(find.text('Worktree has uncommitted changes'), findsOneWidget);
    await tester.tap(find.text('Discard and Remove'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Force removal happened, then the branch delete succeeded (merged).
    expect(git.removedWorktrees, ['/wt/held']);
    expect(git.removeWorktreeForce, [true]);
    expect(git.branchDeletes, [('held', false), ('held', false)]);
  });

  testWidgets(
    'the current branch offers Set upstream via its right-click menu',
    (tester) async {
      final git = await _pump(tester);

      await _rightClick(tester, find.text('main'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set upstream…'));
      await tester.pumpAndSettle();

      // The prompt pre-fills origin/<branch>; confirm as-is.
      await tester.tap(find.text('Set Upstream'));
      await tester.pumpAndSettle();

      expect(git.upstreamsSet, [('main', 'origin/main')]);
    },
  );

  testWidgets('the Remote Branches header fetch-and-prune button runs fetch', (
    tester,
  ) async {
    final git = await _pump(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.arrow_2_circlepath,
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
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider(
          _repo,
        ).overrideWith((ref) async => const <String>{}),
        remoteTagsProvider(_repoB).overrideWith((ref) async => null),
        branchForgeProvider(_repoB).overrideWith((ref) async => const {}),
        mergedBranchesProvider(
          _repoB,
        ).overrideWith((ref) async => const <String>{}),
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
    expect(
      _selectedRows(),
      findsNothing,
      reason: 'a selection must never survive into another repo',
    );
  });

  testWidgets('Review mode + shift-extend puts the batch bar on screen', (
    tester,
  ) async {
    // Guards every other batch test in this file: if this stops selecting two
    // rows, the rest would pass against a bar that never rendered.
    await _pumpBatch(tester);
    await _selectTwoInReview(tester);
    expect(_batchBarLabels(), [
      'Pin',
      'Unpin',
      'Hide',
      'Delete if merged…',
    ], reason: 'the four batch actions, in order');
  });

  testWidgets('batch Pin pins every eligible branch in the selection', (
    tester,
  ) async {
    final identity = await _pumpBatch(tester);
    await _selectTwoInReview(tester);

    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    final prefs = await loadBranchWorkspacePrefs(
      identity: identity,
      legacyRepoPath: _repo,
    );
    expect(prefs.pinnedBranchNames, ['feature', 'main']);
  });

  testWidgets('batch Unpin clears the whole selection again', (tester) async {
    final identity = await _pumpBatch(tester);
    await _selectTwoInReview(tester);

    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();

    final prefs = await loadBranchWorkspacePrefs(
      identity: identity,
      legacyRepoPath: _repo,
    );
    expect(prefs.pinnedBranchNames, isEmpty);
  });

  testWidgets('batch Hide skips the current branch and says so', (
    tester,
  ) async {
    // `main` is HEAD, and MADR 0003 makes current/pinned/protected/
    // worktree-held branches unhideable — so a two-row selection hides exactly
    // one. The skip must be REPORTED, not silent: skipping quietly reads as
    // "the button did nothing" (branches_view.dart:747,778).
    final identity = await _pumpBatch(tester);
    await _selectTwoInReview(tester);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();

    final prefs = await loadBranchWorkspacePrefs(
      identity: identity,
      legacyRepoPath: _repo,
    );
    expect(prefs.hiddenBranchNames, ['feature']);
    expect(
      find.textContaining('current branch'),
      findsOneWidget,
      reason: 'the skipped branch and its reason must be surfaced',
    );
  });

  testWidgets('"Delete if merged…" is disabled until a base exists', (
    tester,
  ) async {
    // The gate MADR 0035's probe hit: no base, no bulk delete. Pinned so a
    // future change cannot silently offer to delete against nothing.
    await _pumpBatch(tester);
    await _selectTwoInReview(tester);

    final button = tester.widget<InlineActionButton>(
      find.widgetWithText(InlineActionButton, 'Delete if merged…'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('with a base, "Delete if merged…" opens the bulk-delete sheet', (
    tester,
  ) async {
    // Covers the WIRING only — the sheet's own behaviour is
    // branch_bulk_delete_sheet_test.dart's job (5 widget tests there).
    await _pumpBatch(tester, extraOverrides: _withBase());
    await _selectTwoInReview(tester);

    final button = tester.widget<InlineActionButton>(
      find.widgetWithText(InlineActionButton, 'Delete if merged…'),
    );
    expect(button.onPressed, isNotNull, reason: 'a base is available now');

    await tester.tap(find.text('Delete if merged…'));
    await tester.pumpAndSettle();

    expect(
      find.byType(MacosSheet),
      findsOneWidget,
      reason: 'the batch bar must reach the bulk-delete sheet',
    );
  });

  testWidgets('a batch hide whose panel is disposed mid-write touches nothing', (
    tester,
  ) async {
    // MADR 0034 F2. `_batchHide` awaits `_updateWorkspacePrefs` — the UI
    // identity, then disk — and used to run `ref.invalidate(...)` and
    // `setState(...)` afterwards with no `mounted` check, even though the very
    // next statement checks one (branches_view.dart:778).
    final parked = Completer<RepositoryUiIdentity?>();
    await _pumpBatch(tester, identityFuture: parked.future);
    await _selectTwoInReview(tester);

    await tester.tap(find.text('Hide'));
    await tester.pump(); // now parked inside _updateWorkspacePrefs

    // The panel goes away while the prefs write is still outstanding.
    await tester.pumpWidget(const MacosApp(home: Text('gone')));
    await tester.pump();

    // Completed with a REAL identity, not null: completing with null would make
    // this depend on `_updateWorkspacePrefs`'s `identity == null` early return
    // (branches_view.dart:992), an implementation detail a refactor could move.
    // A real identity runs the whole write and still lands on the code under
    // test.
    parked.complete(_batchIdentity());
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the resumed continuation must not touch a disposed State',
    );
  });

  testWidgets('a bulk delete whose panel is disposed while the sheet is open '
      'touches nothing', (tester) async {
    // MADR 0034 F3. `_bulkDeleteSelected` checks `mounted` BEFORE awaiting
    // `showBranchBulkDeleteSheet` — a modal, so the window is however long the
    // user takes — and never re-checks before `_refresh()` and `setState(...)`.
    //
    // The sheet is pushed on the ROOT navigator, so it outlives the panel;
    // disposing only the panel needs the app to stay mounted, which is what
    // `panelVisible` is for.
    final panelVisible = ValueNotifier(true);
    addTearDown(panelVisible.dispose);
    await _pumpBatch(
      tester,
      extraOverrides: _withBase(),
      panelVisible: panelVisible,
      refs: _refsFullOid,
    );
    await _selectTwoInReview(tester);

    await tester.tap(find.text('Delete if merged…'));
    await tester.pumpAndSettle();
    expect(find.byType(MacosSheet), findsOneWidget);

    // The delete must actually RUN. Cancelling pops `null`, and
    // `_bulkDeleteSelected` guards its `_refresh()`/`setState` behind
    // `if (results != null)` — so a cancelled sheet never reaches the code
    // under test, and a reproduction that only cancels passes for the wrong
    // reason.
    await tester.tap(find.textContaining('Delete 1'));
    await tester.pumpAndSettle();

    // The panel goes away underneath the open, finished sheet.
    panelVisible.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(BranchesView), findsNothing, reason: 'panel disposed');
    expect(find.byType(MacosSheet), findsOneWidget, reason: 'sheet survived');

    // Closing resolves the await inside the now-disposed panel.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the resumed continuation must not touch a disposed State',
    );
  });
}
