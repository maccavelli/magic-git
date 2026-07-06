// Focused coverage for RepoStatusView — previously the least-tested
// significant file in the app (only Push, via push_logs_output_test.dart).
// Exercises stage/unstage, Stage All, the pending-op banner's Abort action,
// and conflict resolution end-to-end through the real widget tree.

import 'dart:async';

import 'package:flutter/cupertino.dart';
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
  bool stageAllCalled = false;
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

  @override
  Future<PendingOp> pendingOp(String repoPath) async => pendingOp0;
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
      // A refsProvider that never resolves during the test — `.value` stays
      // null throughout, which must read as "unknown" (hide the label), not
      // "no remote" (show it).
      final neverCompletes = Completer<List<GitRef>>();
      addTearDown(() {
        if (!neverCompletes.isCompleted) neverCompletes.complete(const []);
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
}
