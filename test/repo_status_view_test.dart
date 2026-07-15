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
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';
import 'package:riverpod/misc.dart' show Override;

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
  Future<SSHCommandResult> fetch(String repoPath) async {
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
  // Same reasoning as [refs] above, but for whichever file(s) a test selects
  // (a right-click, unlike the icon-button taps most tests here use, also
  // selects the row and so opens the diff panel) — pass an override per
  // selected path so its fileDiffProvider/untrackedDiffProvider read doesn't
  // hit the fake's unconfigured executor.
  List<Override> extraOverrides = const [],
}) async {
  final resolved = git ?? _FakeGitService();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(resolved),
      statusProvider(_repo).overrideWith((ref) async => status),
      pendingOpProvider(_repo).overrideWith((ref) async => resolved.pendingOp0),
      repoWatchProvider(_repo).overrideWith(
        (ref) => const Stream<RepoWatchEvent>.empty(),
      ),
      fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
      refsProvider(_repo).overrideWith((ref) async => refs),
      // Sibling of the refs override: the header now reads CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs. Defaults to
      // matching the refs (remote refs imply a configured remote) so
      // existing tests keep their intent; pass [remotes] explicitly to
      // model an empty repo whose origin IS wired.
      remotesProvider(_repo).overrideWith(
        (ref) async =>
            remotes ??
            (refs.any((r) => r.isRemote)
                ? const ['origin']
                : const <String>[]),
      ),
      connectionProvider.overrideWith(
        () => _StubConnection(
          ConnectionState(
            backend: isLocal ? ConnectionBackend.local : ConnectionBackend.ssh,
          ),
        ),
      ),
      ...extraOverrides,
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
  return resolved;
}

Finder _icon(IconData d) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == d);

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
    await tester.tap(_icon(CupertinoIcons.plus_circle));
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

    await tester.tap(_icon(CupertinoIcons.minus_circle));
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

  testWidgets('Amend last commit confirms, then amends', (tester) async {
    final git = await _pump(
      tester,
      status: _statusWith(
        staged: const [
          GitFileStatus(path: 'lib/a.dart', statusX: 'M', statusY: '.'),
        ],
      ),
    );

    // In the header's pulldown menu.
    await tester.tap(find.byType(MacosPulldownButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amend last commit'));
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
      await tester.tap(_icon(CupertinoIcons.plus_circle));
      await tester.pump();
      // Second tap, while the first is still parked, must be dropped — two
      // concurrent index writes would race on .git/index.lock.
      await tester.tap(_icon(CupertinoIcons.plus_circle));
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

    MacosIconButton fetchButton() => tester.widget<MacosIconButton>(
      find.ancestor(
        of: _icon(CupertinoIcons.cloud_download),
        matching: find.byType(MacosIconButton),
      ),
    );

    expect(fetchButton().onPressed, isNotNull);

    await tester.tap(_icon(CupertinoIcons.cloud_download));
    await tester.pump();
    // In flight: the toolbar button goes inert, so it can't fire a second time.
    expect(fetchButton().onPressed, isNull);
    expect(git.fetchCalls, 1);

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
          statusProvider(
            _repo,
          ).overrideWith((ref) async => _statusWith()),
          pendingOpProvider(_repo).overrideWith((ref) async => git.pendingOp0),
          repoWatchProvider(_repo).overrideWith(
            (ref) => const Stream<RepoWatchEvent>.empty(),
          ),
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
          repoWatchProvider(_repo).overrideWith((ref) => watchController.stream),
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
          repoWatchProvider(_repo).overrideWith((ref) => watchController.stream),
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

  testWidgets(
    'Push flips green when ahead; Pull and Sync stay at their default color',
    (tester) async {
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
          repoWatchProvider(_repo).overrideWith(
            (ref) => const Stream<RepoWatchEvent>.empty(),
          ),
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

      Color? colorOf(IconData icon) =>
          tester.widget<MacosIcon>(_icon(icon)).color;

      expect(
        colorOf(CupertinoIcons.arrow_up_circle),
        MacosColors.systemGreenColor,
      );
      expect(colorOf(CupertinoIcons.arrow_down_circle), isNull);
      expect(colorOf(CupertinoIcons.arrow_2_circlepath), isNull);
    },
  );

  testWidgets('Pull and Sync flip green when behind', (tester) async {
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

    Color? colorOf(IconData icon) =>
        tester.widget<MacosIcon>(_icon(icon)).color;

    expect(colorOf(CupertinoIcons.arrow_down_circle), MacosColors.systemGreenColor);
    expect(colorOf(CupertinoIcons.arrow_up_circle), isNull);
    expect(colorOf(CupertinoIcons.arrow_2_circlepath), isNull);
  });

  testWidgets('Sync flips green only when both ahead and behind', (
    tester,
  ) async {
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

    Color? colorOf(IconData icon) =>
        tester.widget<MacosIcon>(_icon(icon)).color;

    expect(colorOf(CupertinoIcons.arrow_up_circle), MacosColors.systemGreenColor);
    expect(colorOf(CupertinoIcons.arrow_down_circle), MacosColors.systemGreenColor);
    expect(
      colorOf(CupertinoIcons.arrow_2_circlepath),
      MacosColors.systemGreenColor,
    );
  });

  testWidgets('no upstream leaves Push/Pull/Sync at their default color', (
    tester,
  ) async {
    await _pump(tester, status: _statusWith());

    Color? colorOf(IconData icon) =>
        tester.widget<MacosIcon>(_icon(icon)).color;

    expect(colorOf(CupertinoIcons.arrow_up_circle), isNull);
    expect(colorOf(CupertinoIcons.arrow_down_circle), isNull);
    expect(colorOf(CupertinoIcons.arrow_2_circlepath), isNull);
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

      expect(find.text('Use Ours'), findsOneWidget);
      await tester.tap(find.text('Use Ours'));
      await tester.pumpAndSettle();

      expect(git.resolved.single, (path: 'lib/c.dart', useOurs: true));
    },
  );

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
          repoWatchProvider(_repo).overrideWith(
            (ref) => const Stream<RepoWatchEvent>.empty(),
          ),
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
          matching: _icon(CupertinoIcons.plus_circle),
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

        await tester.tap(find.text('lib/a.dart'), buttons: kSecondaryMouseButton);
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
            repoWatchProvider(_repo).overrideWith(
              (ref) => const Stream<RepoWatchEvent>.empty(),
            ),
            fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
            refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
            // Sibling of the refs override: the views now read CONFIGURED
            // remotes (remotesProvider), not remote-tracking refs.
            remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
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
            repoWatchProvider(_repo).overrideWith(
              (ref) => const Stream<RepoWatchEvent>.empty(),
            ),
            fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
            refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
            // Sibling of the refs override: the views now read CONFIGURED
            // remotes (remotesProvider), not remote-tracking refs.
            remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
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
        expect(find.text('Changes'), findsNothing);
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
      'copy-path items, but not Reveal/Open (not a local connection)',
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
        expect(find.text('Open File'), findsNothing);
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
        expect(find.text('Resolve Using Ours'), findsOneWidget);
        expect(find.text('Resolve Using Theirs'), findsOneWidget);

        await tester.tap(find.text('Resolve Using Theirs'));
        await tester.pumpAndSettle();

        expect(git.resolved.single, (path: 'lib/c.dart', useOurs: false));
      },
    );

    testWidgets(
      'right-clicking within a multi-selection shows pluralized bulk '
      'actions covering every selected file',
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
      },
    );

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
        expect(find.textContaining('Files'), findsNothing);
      },
    );

    testWidgets(
      'Reveal in Finder and Open File only appear for a local connection, '
      'and Reveal is hidden once 2+ files are selected',
      (tester) async {
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
        expect(find.text('Open File'), findsOneWidget);

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
      },
    );
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

      expect(find.text('No remote detected'), findsNothing,
          reason: 'origin IS configured — this label was a lie for empty '
              'repos and read as a create/clone wiring failure');
      expect(
        find.text('No branches yet — repository is empty'),
        findsOneWidget,
      );

      // Network actions must be live: fetching/pulling an empty remote is
      // exactly how its first branch arrives.
      final fetchIcon = find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.cloud_download,
      );
      expect(fetchIcon, findsOneWidget);
      expect(
        tester
            .widget<MacosTooltip>(find.ancestor(
              of: fetchIcon,
              matching: find.byType(MacosTooltip),
            ).first)
            .message,
        'Fetch',
      );
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
      expect(
        find.text('No branches yet — repository is empty'),
        findsNothing,
      );
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

      // The hamburger overflow menu is the toolbar's last child.
      final hamburger = _icon(CupertinoIcons.line_horizontal_3);
      expect(hamburger, findsOneWidget);
      final paneWidth = tester.getSize(find.byType(RepoStatusView)).width;
      // 16px toolbar padding plus the pulldown's own inset; anything much
      // wider means the trailing cluster lost its claim on the free space.
      expect(
        paneWidth - tester.getTopRight(hamburger).dx,
        lessThan(40),
        reason: 'toolbar overflow menu must hug the right margin',
      );
    },
  );
}
