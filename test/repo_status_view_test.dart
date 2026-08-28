// Focused coverage for RepoStatusView — previously the least-tested
// significant file in the app (only Push, via push_logs_output_test.dart).
// Exercises stage/unstage, Stage All, the pending-op banner's Abort action,
// and conflict resolution end-to-end through the real widget tree.

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/repo_tree.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/palette_intents.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';
import 'package:remote_magic_git/features/common/status_style.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/common/workspace_focus.dart';
import 'package:remote_magic_git/features/common/workspace_navigation.dart';
import 'package:remote_magic_git/features/dnd/deselect.dart';
import 'package:remote_magic_git/features/repository/commit_composer.dart';
import 'package:remote_magic_git/features/repository/commit_dialog.dart';
import 'package:remote_magic_git/features/repository/diff_popout_window.dart';
import 'package:remote_magic_git/features/repository/diff_view_controls.dart';
import 'package:remote_magic_git/features/repository/repo_change_navigator.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/srv/repo';

// A remote-tracking ref, so the header's `hasRemote` is true and the network
// actions (Fetch/Pull/Push/Sync) are enabled. Tests that exercise those
// buttons must supply this; the default empty `refs` means "no remote", which
// now (correctly) disables them.
const _remoteRefs = [
  GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'deadbeef',
    isHead: false,
    subject: 'Initial commit',
  ),
];

class _FakeGitService extends GitService {
  _FakeGitService() : super(SSHCommandExecutor(SSHClientManager()));

  final List<String> staged = [];
  final List<String> unstaged = [];
  final List<String> discarded = [];
  final List<String> removedUntracked = [];
  final List<String> discardedStaged = [];
  final List<String> gitignored = [];
  bool stageAllCalled = false;
  bool unstageAllCalled = false;
  bool amendCalled = false;
  bool mergeAbortCalled = false;
  final List<({String path, bool useOurs})> resolved = [];
  PendingOp pendingOp0 = PendingOp.none;

  // When set, the matching op parks on this future until the test completes it —
  // lets a test hold an operation "in flight" and prove a second invocation is
  // ignored while the first runs.
  Completer<void>? stageGate;
  Completer<void>? fetchGate;
  int fetchCalls = 0;

  @override
  Future<void> stage(String repoPath, String path) async {
    if (stageGate != null) await stageGate!.future;
    staged.add(path);
  }

  @override
  Future<SSHCommandResult> fetch(
    String repoPath, {
    bool background = false,
    FetchScope scope = FetchScope.allRemotes,
  }) async {
    fetchCalls++;
    if (fetchGate != null) await fetchGate!.future;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> unstage(String repoPath, String path) async {
    unstaged.add(path);
  }

  @override
  Future<void> stageAll(String repoPath) async {
    stageAllCalled = true;
  }

  @override
  Future<void> unstageAll(String repoPath) async {
    unstageAllCalled = true;
  }

  @override
  Future<void> amendCommit(String repoPath, {String? message}) async {
    amendCalled = true;
  }

  @override
  Future<void> mergeAbort(String repoPath) async {
    mergeAbortCalled = true;
  }

  @override
  Future<void> resolveConflict(
    String repoPath,
    String path, {
    required bool useOurs,
  }) async {
    resolved.add((path: path, useOurs: useOurs));
  }

  /// The conflict pane's content. Stubbed because a mutation now marks the
  /// worktree-backed caches stale (see RepoStatusView._refresh), so the pane
  /// re-reads the file after a resolve — which is the point: `git checkout
  /// --ours` rewrites it, and the markers have to go. Without this the fake
  /// fell through to the real SSH executor and left its retry timer pending.
  @override
  Future<String> conflictFile(String repoPath, String path) async =>
      '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n';

  @override
  Future<void> discard(String repoPath, String path) async {
    discarded.add(path);
  }

  @override
  Future<void> removeUntrackedFile(String repoPath, String path) async {
    removedUntracked.add(path);
  }

  @override
  Future<void> discardStaged(String repoPath, String path) async {
    discardedStaged.add(path);
  }

  @override
  Future<void> addToGitignore(String repoPath, String path) async {
    gitignored.add(path);
  }

  @override
  Future<void> stageMany(String repoPath, List<String> paths) async {
    staged.addAll(paths);
  }

  @override
  Future<void> unstageMany(String repoPath, List<String> paths) async {
    unstaged.addAll(paths);
  }

  @override
  Future<void> discardMany(String repoPath, List<String> paths) async {
    discarded.addAll(paths);
  }

  @override
  Future<void> removeUntrackedFilesMany(
    String repoPath,
    List<String> paths,
  ) async {
    removedUntracked.addAll(paths);
  }

  @override
  Future<void> discardStagedMany(String repoPath, List<String> paths) async {
    discardedStaged.addAll(paths);
  }

  @override
  Future<void> addToGitignoreMany(String repoPath, List<String> paths) async {
    gitignored.addAll(paths);
  }

  @override
  Future<void> resolveConflictMany(
    String repoPath,
    List<String> paths, {
    required bool useOurs,
  }) async {
    resolved.addAll(paths.map((p) => (path: p, useOurs: useOurs)));
  }

  @override
  Future<PendingOp> pendingOp(String repoPath) async => pendingOp0;

  // The status view now *prefetches* diffs for the first few changed files
  // whenever status lands (see RepoStatusView._prefetchDiffs), so every file
  // in a test's status — not just the ones a test selects — gets its diff
  // provider created. Serve them from the fake rather than letting them fall
  // through to the real (unconfigured) executor, whose failure would leave
  // erroring providers retrying in the background of every test.
  @override
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) async => 'diff --git a/$path b/$path\n';

  @override
  Future<String> diffUntracked(String repoPath, String path) async =>
      'diff --git a/dev/null b/$path\n';
}

/// The file view is on by default; hide it so it doesn't call listWorkingTree
/// against the fake's real (unconfigured) executor during the test.
class _HiddenFileView extends FileViewVisibility {
  @override
  bool build() => false;
}

/// Kept visible for tests that stub `repoStructureProvider` and exercise the
/// tree → panel routing.
class _VisibleFileView extends FileViewVisibility {
  @override
  bool build() => true;
}

GitStatus _statusWith({
  List<GitFileStatus> staged = const [],
  List<GitFileStatus> unstaged = const [],
  List<GitFileStatus> conflicted = const [],
}) => GitStatus(
  branch: const GitBranchInfo(),
  files: [...staged, ...unstaged, ...conflicted],
);

/// A ConnectionController stuck at a fixed state, so a test can pin
/// `isLocal` without running a real connect — see local_backend_test.dart.
class _StubConnection extends ConnectionController {
  final ConnectionState _state;
  _StubConnection(this._state);
  @override
  ConnectionState build() => _state;
}

/// The container backing the most recent [_pump] — for tests that drive
/// providers directly (e.g. workspace-navigation reveals).
ProviderContainer? _lastContainer;

Future<_FakeGitService> _pump(
  WidgetTester tester, {
  required GitStatus status,
  _FakeGitService? git,
  // Defaulted (not left unmocked) like every other provider here: the real
  // GitService.refs() against the fake's unconfigured executor throws, and
  // GitService's retry-on-read logic schedules a real 400ms backoff Timer
  // before rethrowing — which the test framework flags as "a Timer is still
  // pending" the moment the widget tree is torn down at the end of the test.
  List<GitRef> refs = const [],
  // Configured remotes — null derives from [refs] (see the override below).
  List<String>? remotes,
  // Right-click menu's Reveal-in-Finder/Open-File items are gated on this —
  // default (remote/SSH) matches every other test here, where they must
  // stay hidden.
  bool isLocal = false,
  // Mount the real FileView tree (stub repoStructureProvider via
  // [extraOverrides] when enabling, or it hits the unconfigured executor).
  bool showFileView = false,
  // Same reasoning as [refs] above, but for whichever file(s) a test selects
  // (a right-click, unlike the icon-button taps most tests here use, also
  // selects the row and so opens the diff panel) — pass an override per
  // selected path so its fileDiffProvider/untrackedDiffProvider read doesn't
  // hit the fake's unconfigured executor.
  List<Override> extraOverrides = const [],
  // Gives the panel a live session (repoPath + sessionEpoch) so
  // workspace-navigation restores apply (0009 H3).
  bool sessionful = false,
  Object? statusError,
  // Connect-time forge login still in flight: an auth-looking status error is
  // then in-progress login, not a broken tree, and the pane must show a
  // spinner instead of the dump.
  bool forgeAuthPending = false,
  // A mounted ProgressCircle animates forever, so pumpAndSettle would spin;
  // spinner tests pass `settle: false` and unmount via [_unmount].
  bool settle = true,
}) async {
  final resolved = git ?? _FakeGitService();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(resolved),
      statusProvider(_repo).overrideWith((ref) async {
        if (statusError != null) throw statusError;
        return status;
      }),
      pendingOpProvider(_repo).overrideWith((ref) async => resolved.pendingOp0),
      repoWatchProvider(
        _repo,
      ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
      fileViewVisibleProvider.overrideWith(
        showFileView ? _VisibleFileView.new : _HiddenFileView.new,
      ),
      refsProvider(_repo).overrideWith((ref) async => refs),
      // Sibling of the refs override: the header now reads CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs. Defaults to
      // matching the refs (remote refs imply a configured remote) so
      // existing tests keep their intent; pass [remotes] explicitly to
      // model an empty repo whose origin IS wired.
      remotesProvider(_repo).overrideWith(
        (ref) async =>
            remotes ??
            (refs.any((r) => r.isRemote) ? const ['origin'] : const <String>[]),
      ),
      // Connected, because that is the only state in which this panel is on
      // screen — and the sync group disables every verb while the session is
      // down, since a git command against a dead transport can only fail.
      connectionProvider.overrideWith(
        () => _StubConnection(
          ConnectionState(
            backend: isLocal ? ConnectionBackend.local : ConnectionBackend.ssh,
            phase: ConnectionPhase.connected,
            repoPath: sessionful ? _repo : null,
            sessionEpoch: sessionful ? 1 : 0,
            forgeAuthPending: forgeAuthPending,
          ),
        ),
      ),
      ...extraOverrides,
    ],
  );
  _lastContainer = container;
  addTearDown(container.dispose);
  // A realistic window: the app's default is 1080x720 and its floor is 640x480,
  // but the 800x600 test default sits right where the context bar collapses its
  // sync group, which is not the state most of these tests are about.
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: RepoStatusView(repoPath: _repo),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return resolved;
}

/// Unmounts the tree and drains its tickers before the test ends: a mounted
/// [ProgressCircle] keeps a repeating animation alive, which fails the
/// binding's `!timersPending` assertion at teardown.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

const _syncVerbs = {'Fetch', 'Pull', 'Push', 'Sync'};

/// A sync button's label, whether or not it is carrying a divergence badge
/// (which wraps the label in a Row alongside the count).
String? _verbLabel(AppPushButton button) => switch (button.child) {
  final Text text => text.data,
  final Row row when row.children.first is Text =>
    (row.children.first as Text).data,
  _ => null,
};

/// Every sync verb drawn accented (non-secondary).
///
/// Accent means "worth doing right now", so this is a *set*: two commits up
/// and three down makes Pull, Push and Sync all real options. It replaced the
/// old green icon tint, and then the older single-emphasis rule that let
/// exactly one verb be blue. A disabled verb is never accented.
Set<String> _accentedVerbs(WidgetTester tester) => {
  for (final button in tester.widgetList<AppPushButton>(
    find.byType(AppPushButton),
  ))
    if (_verbLabel(button) case final String label
        when button.secondary != true && _syncVerbs.contains(label))
      label,
};

/// The single verb the ladder recommends — identified by the ahead/behind
/// badge it alone carries. Null when the branch is in sync (no badge to show).
String? _recommendedVerb(WidgetTester tester) {
  for (final button in tester.widgetList<AppPushButton>(
    find.byType(AppPushButton),
  )) {
    if (button.child case final Row row when row.children.first is Text) {
      final label = (row.children.first as Text).data;
      if (label != null && _syncVerbs.contains(label)) return label;
    }
  }
  return null;
}

Finder _icon(IconData d) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == d);

/// The resolved panel binding for [key], mirroring
/// keyboard_shortcuts_test's `_bindingFor` — calling the handler directly
/// sidesteps focus placement, which is not what these tests are about.
VoidCallback? _panelBinding(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool shift = false,
}) {
  for (final element in find.byType(PanelShortcuts).evaluate()) {
    final bindings = (element.widget as PanelShortcuts).bindings;
    for (final entry in bindings.entries) {
      final activator = entry.key;
      if (activator is SingleActivator &&
          activator.trigger == key &&
          activator.meta == meta &&
          activator.shift == shift &&
          !activator.control &&
          !activator.alt) {
        return entry.value;
      }
    }
  }
  return null;
}

void main() {
  testWidgets('tapping Stage on an unstaged file calls git.stage', (
    tester,
  ) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );

    expect(find.text('lib/a.dart'), findsOneWidget);
    await tester.tap(_icon(CupertinoIcons.plus_circle_fill));
    await tester.pumpAndSettle();

    expect(git.staged, ['lib/a.dart']);
  });

  testWidgets('tapping Unstage on a staged file calls git.unstage', (
    tester,
  ) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/b.dart', statusX: 'M', statusY: '.'),
        ],
      ),
    );

    await tester.tap(_icon(CupertinoIcons.minus_circle_fill));
    await tester.pumpAndSettle();

    expect(git.unstaged, ['lib/b.dart']);
  });

  testWidgets('Stage All calls git.stageAll', (tester) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );

    await tester.tap(find.text('Stage All'));
    await tester.pumpAndSettle();

    expect(git.stageAllCalled, isTrue);
  });

  testWidgets('Unstage All mirrors Stage All, enabled only when something '
      'is staged', (tester) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
        ],
      ),
    );

    await tester.tap(find.text('Unstage All'));
    await tester.pumpAndSettle();

    expect(git.unstageAllCalled, isTrue);
  });

  testWidgets('Unstage All is disabled with nothing staged', (tester) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );

    await tester.tap(find.text('Unstage All'));
    await tester.pumpAndSettle();

    expect(git.unstageAllCalled, isFalse);
  });

  // 0008-PLAN B9: ⌘G was a silent no-op under Review, Investigate and Minimal,
  // all of which collapse the task dock the composer lived in. Both surfaces
  // must now reach a composer from a dock-collapsing preset — the sheet by
  // ignoring the layout entirely, the dock by opening itself first.
  group(
    'the commit shortcut reaches a composer under a collapsed task dock',
    () {
      Future<RepositoryUiIdentity> pumpWith(
        WidgetTester tester,
        CommitSurface surface,
      ) async {
        SharedPreferences.setMockInitialValues({});
        addTearDown(() => SharedPreferences.setMockInitialValues({}));
        clearSessionRepositoryWorkspacePrefs();

        // The expanded composer needs more height than the 800x600 default.
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final identity = RepositoryUiIdentity.local(
          localRepoId: 'focus-commit',
          gitCommonDir: '$_repo/.git',
        );
        // The Review preset's dock state, which is also the default.
        await saveRepositoryWorkspacePrefs(
          identity: identity,
          next: RepositoryWorkspacePrefs(
            taskDockCollapsed: true,
            commitSurface: surface,
          ),
        );

        await _pump(
          tester,
          status: _statusWith(
            staged: const [
              GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
            ],
          ),
          extraOverrides: [
            repositoryUiIdentityProvider(
              _repo,
            ).overrideWith((ref) async => identity),
          ],
        );
        return identity;
      }

      void dispatchFocusCommit(WidgetTester tester) {
        // Dispatched on the intent bus rather than as a raw key event: that is
        // the path both the ⌘G binding and the command palette resolve to, and
        // it does not depend on which descendant happens to hold focus.
        ProviderScope.containerOf(tester.element(find.byType(RepoStatusView)))
            .read(paletteIntentProvider.notifier)
            .dispatch('repository.focusCommit');
      }

      final expanded = find.byWidgetPredicate(
        (w) =>
            w is CommitComposer &&
            w.presentation == CommitComposerPresentation.expanded,
      );

      testWidgets('the sheet opens without touching the layout', (
        tester,
      ) async {
        final identity = await pumpWith(tester, CommitSurface.sheet);
        expect(find.byType(CommitDialog), findsNothing);

        dispatchFocusCommit(tester);
        await tester.pumpAndSettle();

        expect(find.byType(CommitDialog), findsOneWidget);
        expect(
          (await loadRepositoryWorkspacePrefs(
            identity: identity,
          )).taskDockCollapsed,
          isTrue,
          reason:
              'a sheet is drawn over the workspace, so it has no business '
              'rewriting the layout to make itself visible',
        );
      });

      testWidgets('the dock opens itself when it is the chosen surface', (
        tester,
      ) async {
        final identity = await pumpWith(tester, CommitSurface.dock);
        expect(expanded, findsNothing);

        dispatchFocusCommit(tester);
        await tester.pumpAndSettle();

        expect(expanded, findsOneWidget);
        expect(find.byType(CommitDialog), findsNothing);
        expect(
          (await loadRepositoryWorkspacePrefs(
            identity: identity,
          )).taskDockCollapsed,
          isFalse,
          reason: 'the dock the composer lives in must actually be open',
        );
      });
    },
  );

  testWidgets('Amend last commit confirms, then amends', (tester) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
        ],
      ),
    );

    // Amend's home is the Repository menu and the palette now that the second
    // toolbar band is gone; both arrive on the intent bus, which is the path
    // exercised here.
    ProviderScope.containerOf(
      tester.element(find.byType(RepoStatusView)),
    ).read(paletteIntentProvider.notifier).dispatch('repository.amend');
    await tester.pumpAndSettle();

    // Nothing runs until the rewrite is confirmed.
    expect(git.amendCalled, isFalse);
    await tester.tap(find.text('Amend'));
    await tester.pumpAndSettle();

    expect(git.amendCalled, isTrue);
  });

  testWidgets(
    'a second Stage tap while the first is in flight is ignored (busy gate)',
    (tester) async {
      final git = _FakeGitService()..stageGate = Completer<void>();
      await _pump(
        tester,
        git: git,
        status: _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          ],
        ),
      );

      // First tap starts the (gated) stage and flips _busy.
      await tester.tap(_icon(CupertinoIcons.plus_circle_fill));
      await tester.pump();
      // Second tap, while the first is still parked, must be dropped — two
      // concurrent index writes would race on .git/index.lock.
      await tester.tap(_icon(CupertinoIcons.plus_circle_fill));
      await tester.pump();

      git.stageGate!.complete();
      await tester.pumpAndSettle();

      expect(git.staged, ['lib/a.dart']); // exactly one, not two
    },
  );

  testWidgets('the Fetch button disables while a fetch is in flight', (
    tester,
  ) async {
    final git = _FakeGitService()..fetchGate = Completer<void>();
    await _pump(tester, git: git, status: _statusWith(), refs: _remoteRefs);

    AppPushButton fetchButton() => tester
        .widgetList<AppPushButton>(find.byType(AppPushButton))
        .firstWhere(
          (button) =>
              button.child is Text && (button.child as Text).data == 'Fetch',
        );

    expect(fetchButton().onPressed, isNotNull);

    await tester.tap(find.text('Fetch'));
    await tester.pump();
    // In flight: sync verbs go inert so none can fire a second time. Staging
    // and Stash stay available — fetch does not hold the mutation busy gate.
    expect(fetchButton().onPressed, isNull);
    expect(git.fetchCalls, 1);
    final stash = tester.widget<ToolIconButton>(
      find.byWidgetPredicate(
        (w) => w is ToolIconButton && w.tooltip == 'Stash changes',
      ),
    );
    expect(stash.onPressed, isNotNull);

    git.fetchGate!.complete();
    await tester.pumpAndSettle();

    // Re-enabled once the op completes, with still just the one call.
    expect(fetchButton().onPressed, isNotNull);
    expect(git.fetchCalls, 1);
  });

  testWidgets(
    'the pending-op banner appears for an in-progress merge, and Abort '
    'confirms then calls mergeAbort',
    (tester) async {
      final git = _FakeGitService()..pendingOp0 = PendingOp.merge;
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          statusProvider(_repo).overrideWith((ref) async => _statusWith()),
          pendingOpProvider(_repo).overrideWith((ref) async => git.pendingOp0),
          repoWatchProvider(
            _repo,
          ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: RepoStatusView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Merge in progress'), findsOneWidget);

      await tester.tap(find.text('Abort Merge'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(git.mergeAbortCalled, isFalse, reason: 'not yet confirmed');

      // Confirm the dialog — its own button is the more-recently-added match.
      await tester.tap(find.text('Abort').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(git.mergeAbortCalled, isTrue);
    },
  );

  testWidgets(
    'a watch tick shortly after this app\'s own action is suppressed (the '
    'explicit refresh already covered it); a later tick still refreshes',
    (tester) async {
      final git = _FakeGitService();
      final watchController = StreamController<RepoWatchEvent>.broadcast();
      addTearDown(watchController.close);
      var statusFetches = 0;
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          statusProvider(_repo).overrideWith((ref) async {
            statusFetches++;
            return _statusWith(
              unstaged: const [
                GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
              ],
            );
          }),
          pendingOpProvider(_repo).overrideWith((ref) async => git.pendingOp0),
          repoWatchProvider(
            _repo,
          ).overrideWith((ref) => watchController.stream),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: RepoStatusView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(statusFetches, 1, reason: 'initial build fetch');

      // Stage All: the explicit, immediate _refresh() invalidates status.
      await tester.tap(find.text('Stage All'));
      await tester.pumpAndSettle();
      expect(statusFetches, 2);

      // The watcher noticing that very same write, moments later.
      watchController.add(
        RepoWatchEvent(at: DateTime.now(), mode: WatchMode.eventDriven),
      );
      await tester.pumpAndSettle();
      expect(
        statusFetches,
        2,
        reason: 'suppressed — this tick is almost certainly our own change',
      );

      // A tick clearly outside the suppression window still refreshes.
      watchController.add(
        RepoWatchEvent(
          at: DateTime.now().add(const Duration(seconds: 10)),
          mode: WatchMode.eventDriven,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        statusFetches,
        3,
        reason: 'a genuinely later tick must still trigger a refresh',
      );
    },
  );

  testWidgets(
    'while hidden, a watch tick does not refetch status; becoming visible '
    're-syncs once',
    (tester) async {
      final git = _FakeGitService();
      final watchController = StreamController<RepoWatchEvent>.broadcast();
      addTearDown(watchController.close);
      var statusFetches = 0;
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          statusProvider(_repo).overrideWith((ref) async {
            statusFetches++;
            return _statusWith(
              unstaged: const [
                GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
              ],
            );
          }),
          pendingOpProvider(_repo).overrideWith((ref) async => git.pendingOp0),
          repoWatchProvider(
            _repo,
          ).overrideWith((ref) => watchController.stream),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        ],
      );
      addTearDown(container.dispose);

      Widget host(bool active) => UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: RepoStatusView(repoPath: _repo, isActive: active),
        ),
      );

      // Start hidden (another tab is up).
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(statusFetches, 1, reason: 'initial build still fetches once');

      // A polling tick while hidden must NOT trigger a background refetch — even
      // one well outside the own-mutation suppression window.
      watchController.add(
        RepoWatchEvent(
          at: DateTime.now().add(const Duration(seconds: 10)),
          mode: WatchMode.polling,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        statusFetches,
        1,
        reason: 'hidden page skips the watch-driven refetch',
      );

      // Becoming visible re-syncs exactly once so nothing is left stale.
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(statusFetches, 2, reason: 'became active → a single re-sync');
    },
  );

  testWidgets('ahead of upstream recommends Push, and only Push', (
    tester,
  ) async {
    final git = _FakeGitService();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(
              head: 'main',
              upstream: 'origin/main',
              ahead: 2,
            ),
            files: const [],
          ),
        ),
        pendingOpProvider(_repo).overrideWith((ref) async => git.pendingOp0),
        repoWatchProvider(
          _repo,
        ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
        refsProvider(_repo).overrideWith((ref) async => const []),
        // Sibling of the refs override: the views now read CONFIGURED
        // remotes (remotesProvider), not remote-tracking refs.
        remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: RepoStatusView(repoPath: _repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The ladder still names Push, and the badge it carries is how you can
    // tell. This fixture configures NO remote, though, so nothing can
    // actually run — and accent tracks what can run, not what is advised.
    expect(_recommendedVerb(tester), 'Push');
    expect(_accentedVerbs(tester), isEmpty);
  });

  testWidgets('behind upstream recommends Pull', (tester) async {
    await _pump(
      tester,
      status: GitStatus(
        branch: const GitBranchInfo(
          head: 'main',
          upstream: 'origin/main',
          behind: 3,
        ),
        files: const [],
      ),
    );

    expect(_accentedVerbs(tester), {'Fetch', 'Pull'});
    expect(_recommendedVerb(tester), 'Pull');
  });

  testWidgets('diverged in both directions recommends Sync', (tester) async {
    await _pump(
      tester,
      status: GitStatus(
        branch: const GitBranchInfo(
          head: 'main',
          upstream: 'origin/main',
          ahead: 1,
          behind: 1,
        ),
        files: const [],
      ),
    );

    // Diverged both ways: every verb is a real option, and the ladder still
    // names one of them as the recommendation.
    expect(_accentedVerbs(tester), _syncVerbs);
    expect(_recommendedVerb(tester), 'Sync');
  });

  testWidgets('the toolbar divergence badge hides entirely when in sync', (
    tester,
  ) async {
    // Tracking upstream, zero ahead/behind — the old rendering was a noisy
    // "↑0 ↓0"; nothing at all is the in-sync signal.
    await _pump(
      tester,
      status: GitStatus(
        branch: const GitBranchInfo(head: 'main', upstream: 'origin/main'),
        files: const [],
      ),
    );

    expect(find.textContaining('↑'), findsNothing);
    expect(find.textContaining('↓'), findsNothing);
  });

  testWidgets(
    'a diverged toolbar badge shows only the non-zero arrows, with the '
    'plain-words tooltip',
    (tester) async {
      await _pump(
        tester,
        status: GitStatus(
          branch: const GitBranchInfo(
            head: 'main',
            upstream: 'origin/main',
            ahead: 2,
          ),
          files: const [],
        ),
      );

      // The badge rides the sync group's emphasized verb — the same place the
      // recommendation it explains is drawn — rather than being repeated in a
      // second toolbar band.
      expect(find.text('↑2'), findsOneWidget);
      expect(find.textContaining('↓'), findsNothing, reason: 'behind is 0');
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTooltip &&
              w.message.startsWith('2 commits ahead of, 0 behind origin/main'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('with no remote configured the group still recommends Fetch, '
      'but every verb is disabled and says why', (tester) async {
    await _pump(tester, status: _statusWith());

    // Nothing can run, so nothing is accented — a blue button that does
    // nothing when clicked is worse than a grey one.
    expect(_accentedVerbs(tester), isEmpty);
    expect(
      tester
          .widgetList<AppPushButton>(find.byType(AppPushButton))
          .every((button) => button.onPressed == null),
      isTrue,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message.contains('No remote'),
      ),
      findsWidgets,
    );
  });

  testWidgets(
    'a conflicted file opens the conflict panel; Use Ours resolves it',
    (tester) async {
      final git = await _pump(
        tester,
        status: _statusWith(
          conflicted: const [
            GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
          ],
        ),
      );

      expect(find.text('lib/c.dart'), findsOneWidget);
      await tester.tap(find.text('lib/c.dart'));
      await tester.pumpAndSettle();

      expect(find.text('Use Ours (HEAD)'), findsOneWidget);
      await tester.tap(find.text('Use Ours (HEAD)'));
      await tester.pumpAndSettle();

      expect(git.resolved.single, (path: 'lib/c.dart', useOurs: true));
    },
  );

  // 0009 H6: a hand-edited conflict is resolved with `git add`, not by
  // taking one whole side.
  testWidgets('Mark Resolved on the conflict pane runs git add', (
    tester,
  ) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        conflicted: const [
          GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
        ],
      ),
    );

    await tester.tap(find.text('lib/c.dart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark Resolved'));
    await tester.pumpAndSettle();

    expect(git.staged, ['lib/c.dart']);
    expect(git.resolved, isEmpty);
  });

  // 0009 H5: a tree click on an unmerged path opens the conflict pane, not a
  // plain diff.
  testWidgets('tree-click on a conflicted file opens the conflict pane', (
    tester,
  ) async {
    await _pump(
      tester,
      status: _statusWith(
        conflicted: const [
          GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
        ],
      ),
      showFileView: true,
      extraOverrides: [
        repoStructureProvider(_repo).overrideWith(
          (ref) async => const RepoNode(
            name: '',
            path: '',
            isDir: true,
            children: [
              RepoNode(
                name: 'lib',
                path: 'lib',
                isDir: true,
                children: [
                  RepoNode(name: 'c.dart', path: 'lib/c.dart', isDir: false),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    // The tree shows the leaf name; the change list shows the full path — so
    // this tap can only be the tree row.
    await tester.tap(find.text('c.dart'));
    await tester.pumpAndSettle();

    expect(find.text('Use Ours (HEAD)'), findsOneWidget);
    expect(find.text('Mark Resolved'), findsOneWidget);
  });

  // 0009 M15: during a rebase git swaps ours/theirs — the labels must say so.
  testWidgets('conflict side labels speak rebase during a rebase', (
    tester,
  ) async {
    final git = _FakeGitService()..pendingOp0 = PendingOp.rebase;
    await _pump(
      tester,
      git: git,
      status: _statusWith(
        conflicted: const [
          GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
        ],
      ),
    );

    await tester.tap(find.text('lib/c.dart'));
    await tester.pumpAndSettle();

    expect(find.text('Use Onto (ours)'), findsOneWidget);
    expect(find.text('Use Commit (theirs)'), findsOneWidget);
    expect(find.text('Use Ours (HEAD)'), findsNothing);
  });

  testWidgets(
    'shows "No remote detected" when the repo has zero remote-tracking refs',
    (tester) async {
      await _pump(tester, status: _statusWith(), refs: const []);

      expect(find.text('No remote detected'), findsOneWidget);
    },
  );

  testWidgets(
    'does not show "No remote detected" when a remote-tracking ref exists',
    (tester) async {
      await _pump(
        tester,
        status: _statusWith(),
        refs: const [
          GitRef(
            name: 'refs/remotes/origin/main',
            oid: 'deadbeef',
            isHead: false,
            subject: 'Initial commit',
          ),
        ],
      );

      expect(find.text('No remote detected'), findsNothing);
    },
  );

  testWidgets(
    'does not show "No remote detected" while refs are still loading',
    (tester) async {
      // Providers that never resolve during the test — `.value` stays null
      // throughout, which must read as "unknown" (hide the label), not
      // "no remote" (show it). The label is driven by remotesProvider now;
      // refs get the same treatment since the header reads both.
      final neverCompletes = Completer<List<GitRef>>();
      final remotesNever = Completer<List<String>>();
      addTearDown(() {
        if (!neverCompletes.isCompleted) neverCompletes.complete(const []);
        if (!remotesNever.isCompleted) remotesNever.complete(const []);
      });
      final git = _FakeGitService();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          statusProvider(_repo).overrideWith((ref) async => _statusWith()),
          pendingOpProvider(_repo).overrideWith((ref) async => git.pendingOp0),
          repoWatchProvider(
            _repo,
          ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) => neverCompletes.future),
          remotesProvider(_repo).overrideWith((ref) => remotesNever.future),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: RepoStatusView(repoPath: _repo),
          ),
        ),
      );
      // Not pumpAndSettle — refsProvider deliberately never settles here.
      await tester.pump();
      await tester.pump();

      expect(find.text('No remote detected'), findsNothing);
    },
  );

  group('multi-select', () {
    GitStatus threeUnstagedOneStaged() => _statusWith(
      staged: const [
        GitFileStatus(path: 'lib/d.dart', statusX: 'M', statusY: '.'),
      ],
      unstaged: const [
        GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
        GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
        GitFileStatus(path: 'lib/c.dart', statusX: '.', statusY: 'M'),
      ],
    );

    Future<void> cmdClick(WidgetTester tester, Finder finder) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(finder);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    Future<void> shiftClick(WidgetTester tester, Finder finder) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(finder);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('cmd-click adds a second file to the selection', (
      tester,
    ) async {
      await _pump(tester, status: threeUnstagedOneStaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await cmdClick(tester, find.text('lib/c.dart'));

      expect(find.text('2 files selected'), findsOneWidget);
    });

    testWidgets('cmd-click again removes a file from the selection', (
      tester,
    ) async {
      await _pump(tester, status: threeUnstagedOneStaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await cmdClick(tester, find.text('lib/b.dart'));
      expect(find.text('2 files selected'), findsOneWidget);

      // Toggling b back off collapses to the single-file diff panel (no
      // "files selected" summary), rather than an empty selection.
      await cmdClick(tester, find.text('lib/b.dart'));
      expect(find.text('files selected'), findsNothing);
    });

    testWidgets('shift-click selects the contiguous range from the anchor', (
      tester,
    ) async {
      await _pump(tester, status: threeUnstagedOneStaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await shiftClick(tester, find.text('lib/c.dart'));

      expect(find.text('3 files selected'), findsOneWidget);
    });

    testWidgets('a plain click after a multi-select collapses to just that '
        'file', (tester) async {
      await _pump(tester, status: threeUnstagedOneStaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await cmdClick(tester, find.text('lib/c.dart'));
      expect(find.text('2 files selected'), findsOneWidget);

      await tester.tap(find.text('lib/b.dart'));
      await tester.pumpAndSettle();

      expect(find.textContaining('files selected'), findsNothing);
    });

    testWidgets(
      'clicking into a different section replaces the selection rather '
      'than extending it',
      (tester) async {
        await _pump(tester, status: threeUnstagedOneStaged());

        // Select two unstaged files, then cmd-click the staged file: since
        // it's a different section, this replaces the selection with just
        // the staged file instead of growing it to three.
        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();
        await cmdClick(tester, find.text('lib/b.dart'));
        expect(find.text('2 files selected'), findsOneWidget);

        await cmdClick(tester, find.text('lib/d.dart'));

        expect(find.textContaining('files selected'), findsNothing);
      },
    );

    testWidgets('staging a file that is part of a multi-selection drops it '
        'from the selection rather than reselecting it', (tester) async {
      final git = await _pump(tester, status: threeUnstagedOneStaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await cmdClick(tester, find.text('lib/b.dart'));
      expect(find.text('2 files selected'), findsOneWidget);

      // Stage lib/a.dart via its row icon — it should drop out of the
      // selection (it's moved to a different section), leaving lib/b.dart as
      // the sole (now single-file) selection.
      final aRow = find.ancestor(
        of: find.text('lib/a.dart'),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(
        find.descendant(
          of: aRow,
          matching: _icon(CupertinoIcons.plus_circle_fill),
        ),
      );
      await tester.pumpAndSettle();

      expect(git.staged, ['lib/a.dart']);
      expect(find.textContaining('files selected'), findsNothing);
    });

    testWidgets(
      'bulk Stage re-homes the multi-selection into Staged rather than '
      'leaving it orphaned on the unstaged section',
      (tester) async {
        final git = await _pump(
          tester,
          status: _statusWith(
            unstaged: const [
              GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
              GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
            ],
          ),
        );

        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();
        await cmdClick(tester, find.text('lib/b.dart'));
        expect(find.text('2 files selected'), findsOneWidget);

        await tester.tap(
          find.text('lib/a.dart'),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stage 2 Files'));
        await tester.pumpAndSettle();

        expect(git.staged, ['lib/a.dart', 'lib/b.dart']);
        // Re-homed as a multi-selection (kind follows the files). With the
        // test's fixed status override the paths still appear under Changes,
        // so the status-sync re-homes them back onto unstaged — either way the
        // selection is not cleared. The production path (status refetch after
        // stage) lands them under Staged and keeps kind=staged.
        expect(find.text('2 files selected'), findsOneWidget);
      },
    );

    testWidgets(
      'a status refresh prunes multi-select members that left the section',
      (tester) async {
        // Mutable status so we can simulate an external stage of one member
        // without going through our own stage action's bookkeeping.
        var current = _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
            GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
          ],
        );
        final git = _FakeGitService();
        final container = ProviderContainer(
          overrides: [
            gitServiceProvider.overrideWithValue(git),
            statusProvider(_repo).overrideWith((ref) async => current),
            pendingOpProvider(
              _repo,
            ).overrideWith((ref) async => PendingOp.none),
            repoWatchProvider(
              _repo,
            ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
            fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
            refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
            // Sibling of the refs override: the views now read CONFIGURED
            // remotes (remotesProvider), not remote-tracking refs.
            remotesProvider(
              _repo,
            ).overrideWith((ref) async => const <String>[]),
            connectionProvider.overrideWith(
              () => _StubConnection(
                const ConnectionState(backend: ConnectionBackend.ssh),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MacosApp(
              debugShowCheckedModeBanner: false,
              home: RepoStatusView(repoPath: _repo),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();
        await cmdClick(tester, find.text('lib/b.dart'));
        expect(find.text('2 files selected'), findsOneWidget);

        // External stage of a: still in status.files (as staged), but no
        // longer in the unstaged section the selection claimed.
        current = _statusWith(
          staged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
          ],
          unstaged: const [
            GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
          ],
        );
        container.invalidate(statusProvider(_repo));
        await tester.pumpAndSettle();

        // a pruned; b alone → multi-select summary goes away. b may also
        // appear in the diff chrome once the selection collapses to one file.
        expect(find.textContaining('files selected'), findsNothing);
        expect(find.text('lib/b.dart'), findsWidgets);
      },
    );

    testWidgets(
      'a status refresh re-homes a single selection that moved sections',
      (tester) async {
        var current = _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          ],
        );
        final git = _FakeGitService();
        final container = ProviderContainer(
          overrides: [
            gitServiceProvider.overrideWithValue(git),
            statusProvider(_repo).overrideWith((ref) async => current),
            pendingOpProvider(
              _repo,
            ).overrideWith((ref) async => PendingOp.none),
            repoWatchProvider(
              _repo,
            ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
            fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
            refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
            // Sibling of the refs override: the views now read CONFIGURED
            // remotes (remotesProvider), not remote-tracking refs.
            remotesProvider(
              _repo,
            ).overrideWith((ref) async => const <String>[]),
            connectionProvider.overrideWith(
              () => _StubConnection(
                const ConnectionState(backend: ConnectionBackend.ssh),
              ),
            ),
            // Diff keys for both halves — re-home flips staged:true.
            fileDiffProvider((
              _repo,
              'lib/a.dart',
              false,
              false,
              3,
            )).overrideWith((ref) async => 'diff unstaged'),
            fileDiffProvider((
              _repo,
              'lib/a.dart',
              true,
              false,
              3,
            )).overrideWith((ref) async => 'diff staged'),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MacosApp(
              debugShowCheckedModeBanner: false,
              home: RepoStatusView(repoPath: _repo),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();
        // Diff panel open on the unstaged half.
        expect(find.text('lib/a.dart'), findsWidgets);

        current = _statusWith(
          staged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
          ],
        );
        container.invalidate(statusProvider(_repo));
        await tester.pumpAndSettle();

        // Still selected (re-homed to staged), not cleared — path still shown
        // in the staged section and the diff chrome.
        expect(find.text('lib/a.dart'), findsWidgets);
        expect(find.text('Staged (1)'), findsOneWidget);
        expect(find.text('Changes (1)'), findsNothing);
      },
    );
  });

  group('right-click context menu', () {
    Future<void> rightClick(WidgetTester tester, Finder finder) async {
      await tester.tap(finder, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'an unstaged file offers Stage/Discard Changes/Blame plus the common '
      'copy-path items, but not Reveal (not a local connection)',
      (tester) async {
        await _pump(
          tester,
          status: _statusWith(
            unstaged: const [
              GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
            ],
          ),
          extraOverrides: [
            fileDiffProvider((
              _repo,
              'lib/a.dart',
              false,
              false,
              3,
            )).overrideWith((ref) async => ''),
          ],
        );

        await rightClick(tester, find.text('lib/a.dart'));

        expect(find.text('Stage'), findsOneWidget);
        expect(find.text('Discard Changes'), findsOneWidget);
        expect(find.text('Blame'), findsOneWidget);
        expect(find.text('Copy Relative Path'), findsOneWidget);
        expect(find.text('Copy Path'), findsOneWidget);
        expect(find.text('Reveal in Finder'), findsNothing);
        expect(find.text('Open file'), findsOneWidget);
      },
    );

    testWidgets('tapping Stage in the menu calls git.stage and dismisses it', (
      tester,
    ) async {
      final git = await _pump(
        tester,
        status: _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          ],
        ),
        extraOverrides: [
          fileDiffProvider((
            _repo,
            'lib/a.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => ''),
          fileDiffProvider((
            _repo,
            'lib/a.dart',
            true,
            false,
            3,
          )).overrideWith((ref) async => ''),
        ],
      );

      await rightClick(tester, find.text('lib/a.dart'));
      await tester.tap(find.text('Stage'));
      await tester.pumpAndSettle();

      expect(git.staged, ['lib/a.dart']);
      expect(find.text('Discard Changes'), findsNothing);
    });

    testWidgets(
      'a staged file offers Unstage/Discard Staged Changes; confirming the '
      'latter calls git.discardStaged',
      (tester) async {
        final git = await _pump(
          tester,
          status: _statusWith(
            staged: const [
              GitFileStatus(path: 'lib/b.dart', statusX: 'M', statusY: '.'),
            ],
          ),
          extraOverrides: [
            fileDiffProvider((
              _repo,
              'lib/b.dart',
              true,
              false,
              3,
            )).overrideWith((ref) async => ''),
          ],
        );

        await rightClick(tester, find.text('lib/b.dart'));
        expect(find.text('Unstage'), findsOneWidget);
        expect(find.text('Discard Staged Changes'), findsOneWidget);

        await tester.tap(find.text('Discard Staged Changes'));
        await tester.pumpAndSettle();
        expect(git.discardedStaged, isEmpty, reason: 'not yet confirmed');

        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(git.discardedStaged, ['lib/b.dart']);
      },
    );

    testWidgets(
      'an untracked file offers Stage/Add to .gitignore/Delete Untracked '
      'File; Add to .gitignore calls git.addToGitignore with no confirm',
      (tester) async {
        final git = await _pump(
          tester,
          status: _statusWith(
            unstaged: const [
              GitFileStatus(path: 'lib/new.dart', statusX: '?', statusY: '?'),
            ],
          ),
          extraOverrides: [
            untrackedDiffProvider((
              _repo,
              'lib/new.dart',
            )).overrideWith((ref) async => ''),
          ],
        );

        await rightClick(tester, find.text('lib/new.dart'));
        expect(find.text('Stage'), findsOneWidget);
        expect(find.text('Add to .gitignore'), findsOneWidget);
        expect(find.text('Delete Untracked File'), findsOneWidget);
        // Untracked files have no committed history — Blame doesn't apply.
        expect(find.text('Blame'), findsNothing);

        await tester.tap(find.text('Add to .gitignore'));
        await tester.pumpAndSettle();

        expect(git.gitignored, ['lib/new.dart']);
      },
    );

    testWidgets(
      'Delete Untracked File confirms, then calls git.removeUntrackedFile',
      (tester) async {
        final git = await _pump(
          tester,
          status: _statusWith(
            unstaged: const [
              GitFileStatus(path: 'lib/new.dart', statusX: '?', statusY: '?'),
            ],
          ),
          extraOverrides: [
            untrackedDiffProvider((
              _repo,
              'lib/new.dart',
            )).overrideWith((ref) async => ''),
          ],
        );

        await rightClick(tester, find.text('lib/new.dart'));
        await tester.tap(find.text('Delete Untracked File'));
        await tester.pumpAndSettle();
        expect(git.removedUntracked, isEmpty, reason: 'not yet confirmed');

        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(git.removedUntracked, ['lib/new.dart']);
      },
    );

    testWidgets(
      'a conflicted file offers Resolve Using Ours/Theirs, which call '
      'git.resolveConflict',
      (tester) async {
        final git = await _pump(
          tester,
          status: _statusWith(
            conflicted: const [
              GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
            ],
          ),
        );

        await rightClick(tester, find.text('lib/c.dart'));
        expect(find.text('Resolve Using Ours (HEAD)'), findsOneWidget);
        expect(find.text('Resolve Using Theirs (incoming)'), findsOneWidget);
        // Twice: the conflict pane behind the menu has its own button.
        expect(find.text('Mark Resolved'), findsNWidgets(2));

        await tester.tap(find.text('Resolve Using Theirs (incoming)'));
        await tester.pumpAndSettle();

        expect(git.resolved.single, (path: 'lib/c.dart', useOurs: false));
      },
    );

    testWidgets('Mark Resolved in the conflict context menu stages the file', (
      tester,
    ) async {
      final git = await _pump(
        tester,
        status: _statusWith(
          conflicted: const [
            GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
          ],
        ),
      );

      await rightClick(tester, find.text('lib/c.dart'));
      // The menu overlay's item renders above the pane's own button.
      await tester.tap(find.text('Mark Resolved').last);
      await tester.pumpAndSettle();

      expect(git.staged, ['lib/c.dart']);
      expect(git.resolved, isEmpty);
    });

    testWidgets('right-clicking within a multi-selection shows pluralized bulk '
        'actions covering every selected file', (tester) async {
      final git = await _pump(
        tester,
        status: _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
            GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
          ],
        ),
      );

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(find.text('lib/b.dart'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.text('2 files selected'), findsOneWidget);

      // Right-clicking a row that's part of the selection keeps it intact.
      await rightClick(tester, find.text('lib/a.dart'));
      expect(find.text('Stage 2 Files'), findsOneWidget);
      expect(find.text('Discard Changes in 2 Files'), findsOneWidget);
      // A single-file-only item (Blame) doesn't apply to a bulk selection.
      expect(find.text('Blame'), findsNothing);
      expect(find.text('Copy 2 Relative Paths'), findsOneWidget);

      await tester.tap(find.text('Stage 2 Files'));
      await tester.pumpAndSettle();

      expect(git.staged, ['lib/a.dart', 'lib/b.dart']);
    });

    testWidgets(
      'right-clicking a file outside the current multi-selection collapses '
      'to just that file before showing the menu',
      (tester) async {
        await _pump(
          tester,
          status: _statusWith(
            unstaged: const [
              GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
              GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
              GitFileStatus(path: 'lib/c.dart', statusX: '.', statusY: 'M'),
            ],
          ),
          extraOverrides: [
            fileDiffProvider((
              _repo,
              'lib/c.dart',
              false,
              false,
              3,
            )).overrideWith((ref) async => ''),
          ],
        );

        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.tap(find.text('lib/b.dart'));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
        expect(find.text('2 files selected'), findsOneWidget);

        // lib/c.dart isn't part of the a/b selection — right-clicking it
        // collapses to just itself rather than growing to 3.
        await rightClick(tester, find.text('lib/c.dart'));

        expect(find.text('Stage'), findsOneWidget);
        expect(find.text('3 files selected'), findsNothing);
      },
    );

    testWidgets('Reveal in Finder only appears for a local connection, '
        'and Reveal is hidden once 2+ files are selected', (tester) async {
      await _pump(
        tester,
        isLocal: true,
        status: _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
            GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
          ],
        ),
        extraOverrides: [
          fileDiffProvider((
            _repo,
            'lib/a.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => ''),
        ],
      );

      await rightClick(tester, find.text('lib/a.dart'));
      expect(find.text('Reveal in Finder'), findsOneWidget);
      expect(find.text('Open file'), findsOneWidget);

      // Dismiss, then select both and right-click within the selection.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(find.text('lib/b.dart'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      await rightClick(tester, find.text('lib/a.dart'));

      expect(find.text('Reveal in Finder'), findsNothing);
      expect(find.text('Open 2 Files'), findsOneWidget);
    });
  });

  testWidgets(
    'an EMPTY repo with a configured origin reports "No branches yet", '
    'never "No remote detected" — the wired-but-unfetched state a fresh '
    'create/clone of an empty forge project always lands in',
    (tester) async {
      await _pump(
        tester,
        status: GitStatus(branch: const GitBranchInfo(), files: const []),
        refs: const [], // no refs of ANY kind: unborn HEAD, nothing fetched
        remotes: const ['origin'], // …but the remote config is perfect
      );

      expect(
        find.text('No remote detected'),
        findsNothing,
        reason:
            'origin IS configured — this label was a lie for empty '
            'repos and read as a create/clone wiring failure',
      );
      expect(
        find.text('No branches yet — repository is empty'),
        findsOneWidget,
      );

      // Network actions must be live: fetching/pulling an empty remote is
      // exactly how its first branch arrives.
      final fetch = tester
          .widgetList<AppPushButton>(find.byType(AppPushButton))
          .firstWhere(
            (button) =>
                button.child is Text && (button.child as Text).data == 'Fetch',
          );
      expect(fetch.onPressed, isNotNull);
    },
  );

  testWidgets(
    'a repo with NO configured remotes still reports "No remote detected"',
    (tester) async {
      await _pump(
        tester,
        status: GitStatus(branch: const GitBranchInfo(), files: const []),
        refs: const [],
        remotes: const [],
      );
      expect(find.text('No remote detected'), findsOneWidget);
      expect(find.text('No branches yet — repository is empty'), findsNothing);
    },
  );

  testWidgets(
    'toolbar actions stay flush right with the SSH status chip present — a '
    'loose Flexible sibling must not split the free space with the trailing '
    'cluster and drag the buttons toward the middle',
    (tester) async {
      await _pump(
        tester,
        status: GitStatus(branch: const GitBranchInfo(), files: const []),
        refs: _remoteRefs, // SSH backend is the default here → chip renders
      );

      // The sync group's overflow pull-down is the bar's last child.
      // Title-only: macos_ui paints its own caret (no chevron icon).
      final overflow = find.byWidgetPredicate(
        (w) => w is MacosPulldownButton && w.title == '',
      );
      expect(overflow, findsOneWidget);
      final paneWidth = tester.getSize(find.byType(RepoStatusView)).width;
      // 12px bar padding plus the pulldown's own inset; anything much wider
      // means the trailing cluster lost its claim on the free space — which is
      // what a loose Flexible sibling of the identity's Expanded would cause.
      expect(
        paneWidth - tester.getTopRight(overflow).dx,
        lessThan(40),
        reason: 'the trailing cluster must hug the right margin',
      );
    },
  );

  // The canonical deselect affordances (see lib/features/dnd/deselect.dart):
  // Esc and click-on-empty are the two ways OUT of a selection — including
  // the one an abandoned drag leaves behind.
  group('deselect', () {
    GitStatus twoUnstaged() => _statusWith(
      unstaged: const [
        GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
        GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
      ],
    );

    Finder selectedRows() => find.byWidgetPredicate(
      (w) => w is Container && w.color == AppTheme.rowSelectionTint,
    );

    testWidgets('Esc clears the file selection', (tester) async {
      await _pump(tester, status: twoUnstaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      expect(selectedRows(), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(selectedRows(), findsNothing);
    });

    testWidgets('a click on empty list space clears the selection', (
      tester,
    ) async {
      await _pump(tester, status: twoUnstaged());

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      expect(selectedRows(), findsOneWidget);

      // Well below the last row: inside the list pane, on nothing.
      final rect = tester.getRect(find.byType(DeselectOnEmptyClick));
      await tester.tapAt(Offset(rect.left + 24, rect.bottom - 12));
      await tester.pumpAndSettle();
      expect(selectedRows(), findsNothing);
    });

    testWidgets('one Esc during a live drag cancels the drag AND clears the '
        'selection it made', (tester) async {
      await _pump(tester, status: twoUnstaged());

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('lib/a.dart')),
      );
      await tester.pump(const Duration(milliseconds: 60));
      await gesture.moveBy(const Offset(90, 0));
      await tester.pump();
      // Select-on-drag has selected the row under the drag.
      expect(selectedRows(), findsOneWidget);

      // The shared drag-state handler cancels the drag, then the focus tree
      // (which sees the same key event) clears the selection — one press.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(selectedRows(), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(selectedRows(), findsNothing);
    });
  });

  group('diff pop-out', () {
    testWidgets('arrow-key navigation keeps the pop-out open and follows the '
        'selection, matching a click', (tester) async {
      await _pump(
        tester,
        status: _statusWith(
          unstaged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
            GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
          ],
        ),
      );

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      final diffMenu = find.descendant(
        of: find.byType(DiffViewControls),
        matching: find.byType(MacosPulldownButton),
      );
      await tester.tap(diffMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open diff in larger window'));
      await tester.pumpAndSettle();
      expect(find.byType(DiffPopoutWindow), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      // Popping out relocates WHERE the diff shows, not which — the window
      // stays up and now shows the newly selected file (its title bar path).
      expect(find.byType(DiffPopoutWindow), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(DiffPopoutWindow),
          matching: find.text('lib/b.dart'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('Stage All stays active while a partially-staged file still has '
      'unstaged changes', (tester) async {
    // One record, in BOTH derived lists (added to the index, then edited
    // again): the old files-vs-staged count comparison read this as
    // "everything staged".
    await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/mixed.dart', statusX: 'A', statusY: 'M'),
        ],
      ),
    );

    final stageAll = tester.widget<AppPushButton>(
      find.byWidgetPredicate(
        (w) =>
            w is AppPushButton &&
            w.child is Text &&
            (w.child as Text).data == 'Stage All',
      ),
    );
    expect(
      stageAll.onPressed,
      isNotNull,
      reason: 'the worktree half of a mixed file is still stageable',
    );
    expect(
      stageAll.secondary,
      isFalse,
      reason: 'accent while there is still something to stage',
    );
  });

  // 0009 M12: Space / the discard chord act on the whole multi-selection,
  // through the same bulk helpers the context menu uses.
  testWidgets('Space stages every selected unstaged file', (tester) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );
    await tester.tap(find.text('lib/a.dart'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.text('lib/b.dart'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 files selected'), findsOneWidget);

    final toggle = _panelBinding(tester, LogicalKeyboardKey.space);
    expect(toggle, isNotNull);
    toggle!();
    await tester.pumpAndSettle();

    expect(git.staged, ['lib/a.dart', 'lib/b.dart']);
  });

  testWidgets('the discard chord discards every selected unstaged file', (
    tester,
  ) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );
    await tester.tap(find.text('lib/a.dart'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.text('lib/b.dart'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final discard = _panelBinding(
      tester,
      LogicalKeyboardKey.backspace,
      meta: true,
      shift: true,
    );
    expect(discard, isNotNull);
    discard!();
    await tester.pumpAndSettle();
    // Same confirm the context menu's bulk discard shows.
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(git.discarded, ['lib/a.dart', 'lib/b.dart']);
  });

  // 0009 L8: the Stage All button uses the same gate as its shortcut.
  testWidgets('Stage All dims when nothing is left to stage', (tester) async {
    await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
        ],
      ),
    );

    final stageAll = tester.widget<AppPushButton>(
      find.byWidgetPredicate(
        (w) =>
            w is AppPushButton &&
            w.child is Text &&
            (w.child as Text).data == 'Stage All',
      ),
    );
    expect(stageAll.onPressed, isNull);
  });

  testWidgets(
    'commit bar buttons match size and order Unstage All, Stage All, Commit…',
    (tester) async {
      await _pump(
        tester,
        status: _statusWith(
          staged: const [
            GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
          ],
          unstaged: const [
            GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
          ],
        ),
      );

      AppPushButton button(String label) => tester.widget<AppPushButton>(
        find.byWidgetPredicate(
          (w) =>
              w is AppPushButton &&
              w.child is Text &&
              (w.child as Text).data == label,
        ),
      );

      final unstage = button('Unstage All');
      final stage = button('Stage All');
      final commit = button('Commit…');
      expect(unstage.controlSize, ControlSize.large);
      expect(stage.controlSize, ControlSize.large);
      expect(commit.controlSize, ControlSize.large);
      expect(unstage.secondary, isFalse, reason: 'staged files to unstage');
      expect(stage.secondary, isFalse, reason: 'unstaged files to stage');
      expect(commit.secondary, isFalse, reason: 'staged files to commit');

      final unstageX = tester.getCenter(find.text('Unstage All')).dx;
      final stageX = tester.getCenter(find.text('Stage All')).dx;
      final commitX = tester.getCenter(find.text('Commit…')).dx;
      expect(unstageX, lessThan(stageX));
      expect(stageX, lessThan(commitX));
    },
  );

  // 0009 H3: a revealed (palette / Back-Forward) file location must land on
  // its real section — the conflict pane for an unmerged path.
  testWidgets('a revealed conflicted file opens the conflict pane', (
    tester,
  ) async {
    await _pump(
      tester,
      sessionful: true,
      status: _statusWith(
        conflicted: const [
          GitFileStatus(path: 'lib/c.dart', statusX: 'U', statusY: 'U'),
        ],
      ),
    );
    final container = _lastContainer!;
    const key = WorkspaceSessionKey(_repo, 1);
    const location = WorkspaceFocus(
      repositoryPath: _repo,
      sessionEpoch: 1,
      kind: WorkspaceFocusKind.path,
      identity: 'lib/c.dart',
      panelIndex: 0,
    );

    container.read(workspaceNavigationProvider(key).notifier).reveal(location);
    await tester.pumpAndSettle();

    expect(find.text('Use Ours (HEAD)'), findsOneWidget);
    expect(find.text('Mark Resolved'), findsOneWidget);
    expect(
      container.read(workspaceNavigationProvider(key)).pending,
      isNull,
      reason: 'the adapter consumed the location',
    );
  });

  // 0009 H7: the pulldown's Hide-reviewed toggle must actually thread the
  // review controller's reviewed identities into the list filter.
  testWidgets('Hide reviewed paths hides rows marked reviewed', (tester) async {
    await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );

    // Review all visible → mark the active file (lib/a.dart) reviewed → close.
    await tester.tap(find.text('Review all visible'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark Reviewed'));
    await tester.pumpAndSettle();
    // The review strip shows the check — proves the mark landed.
    expect(find.text('✓ lib/a.dart'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Default filter (include reviewed) still shows the reviewed row.
    expect(find.text('lib/a.dart'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(RepoChangeNavigator),
        matching: find.byType(MacosPulldownButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide reviewed paths'));
    await tester.pumpAndSettle();

    expect(find.text('lib/a.dart'), findsNothing);
    expect(find.text('lib/b.dart'), findsOneWidget);
    // The filter now counts as active: the count shows the hidden row and
    // the Clear-filters affordance appears.
    expect(find.text('1 of 2'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is ToolIconButton && w.tooltip == 'Clear filters',
      ),
      findsOneWidget,
    );
  });

  // 0009 M13: "Review all visible" must cover every visible section, not just
  // the first non-empty one.
  testWidgets('Review all visible walks every section, not just the first', (
    tester,
  ) async {
    await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/staged.dart', statusX: 'M', statusY: '.'),
        ],
        unstaged: const [
          GitFileStatus(path: 'lib/unstaged.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );

    await tester.tap(find.text('Review all visible'));
    await tester.pumpAndSettle();

    // Both sections' files are in the review run — the counter says 2 and the
    // strip lists both paths.
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.textContaining('lib/staged.dart'), findsWidgets);
    expect(find.textContaining('lib/unstaged.dart'), findsWidgets);
  });

  // 0009 M17 (gitlink half): a submodule entry is badged — its "change" is a
  // recorded commit pointer, not file content.
  testWidgets('a submodule change row carries the sub badge', (tester) async {
    await _pump(
      tester,
      status: _statusWith(
        unstaged: const [
          GitFileStatus(
            path: 'vendor/lib',
            statusX: '.',
            statusY: 'M',
            isSubmodule: true,
          ),
          GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );

    expect(find.byType(SubmoduleChip), findsOneWidget);
  });

  testWidgets(
    'a not-logged-in status error is shown once forge login has settled',
    (tester) async {
      await _pump(
        tester,
        status: _statusWith(),
        statusError: const GitException(
          'git status failed',
          SSHCommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'glab: not logged in',
          ),
        ),
      );

      expect(find.textContaining('not logged in'), findsOneWidget);
    },
  );

  testWidgets(
    'a not-logged-in status error shows a spinner while forge login is pending',
    (tester) async {
      await _pump(
        tester,
        status: _statusWith(),
        statusError: const GitException(
          'git status failed',
          SSHCommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'glab: not logged in',
          ),
        ),
        forgeAuthPending: true,
        settle: false,
      );

      expect(find.byType(ProgressCircle), findsWidgets);
      expect(find.textContaining('not logged in'), findsNothing);

      await _unmount(tester);
    },
  );

  testWidgets('a not-ready transport shows a spinner, not an error', (
    tester,
  ) async {
    await _pump(
      tester,
      status: _statusWith(),
      statusError: const SSHTransportNotReady('git status'),
      settle: false,
    );

    expect(find.byType(ProgressCircle), findsWidgets);
    expect(find.textContaining('not ready'), findsNothing);

    await _unmount(tester);
  });

  testWidgets(
    'a non-auth status error is shown even while forge login is pending',
    (tester) async {
      await _pump(
        tester,
        status: _statusWith(),
        statusError: const GitException(
          'git status failed',
          SSHCommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'fatal: not a git repository',
          ),
        ),
        forgeAuthPending: true,
      );

      expect(find.textContaining('not a git repository'), findsOneWidget);
    },
  );
}
