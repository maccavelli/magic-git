// MADR 0039 F6. A watch tick suppressed as "probably our own echo" must be
// DEFERRED, not dropped.
//
// `OwnMutationTracker.isRecent` answers "did we mutate this repo recently",
// not "is this particular event ours" — and it stays true for the entire
// duration of an in-flight operation, which `withOwnMutation` wraps around the
// background fetch and the five-minute auto-fetch. Dropping the tick therefore
// discarded a teammate's push or a terminal commit that happened to land in
// that window, with nothing left to surface it but ⌘R.
//
// This drives the real widget: an external tick arrives while our own operation
// is in flight, and the refresh it should have caused must still happen once
// the operation settles. The *bound* — a flush even while the operation is
// still running — is pinned in `suppressed_tick_test.dart`, which owns an
// injectable clock; `DateTime.now()` is not faked by `tester.pump`.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/srv/repo';

class _StubGit extends GitService {
  _StubGit() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => const [];
}

void main() {
  testWidgets('a tick suppressed during our own operation is replayed, not '
      'lost', (tester) async {
    final ticks = StreamController<RepoWatchEvent>.broadcast();
    addTearDown(ticks.close);
    var snapshots = 0;

    // A tracker pinned to a fixed clock. `tester.pump` fakes Timers but not
    // `DateTime.now()`, so with the real clock `end()`'s mark would still read
    // as "recent" when the deferred timer fires and the tick would re-hold
    // forever. Pinned to the epoch, the in-flight refcount is what suppresses —
    // which is precisely the case this test is about — and `end()` clears it.
    final tracker = OwnMutationTracker(
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );

    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_StubGit()),
        ownMutationTrackerProvider.overrideWithValue(tracker),
        repoWatchProvider(_repo).overrideWith((ref) => ticks.stream),
        // The observable: `_invalidateMutationFamilies` (what an unscoped
        // event-driven tick triggers) invalidates this, so a rebuild here is a
        // refresh having happened.
        repoSnapshotProvider(_repo).overrideWith((ref) async {
          snapshots++;
          return RepoSnapshot(
            status: GitStatus(branch: const GitBranchInfo(), files: const []),
            refs: const [],
            pendingOp: PendingOp.none,
            refParseWarnings: const [],
            remotes: const [],
          );
        }),
        refsProvider(_repo).overrideWith((ref) async => const []),
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
    final baseline = snapshots;

    // Our own operation starts — a background fetch, say — and does not finish.
    // `isRecent` is true for its whole duration.
    tracker.begin(_repo);

    // Somebody else commits on the host. The watcher reports it.
    ticks.add(
      RepoWatchEvent(
        at: DateTime.now(),
        mode: WatchMode.eventDriven,
        paths: const {'.git/refs/heads/main'},
      ),
    );
    await tester.pump();
    expect(
      snapshots,
      baseline,
      reason: 'suppression still works — no immediate second fetch',
    );

    // Our operation settles. The held tick is now due.
    tracker.end(_repo);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(
      snapshots,
      greaterThan(baseline),
      reason:
          'the external change must still reach the UI; before this it was '
          'discarded outright and stayed invisible until ⌘R',
    );
  });

  testWidgets('an ordinary unsuppressed tick still refreshes immediately', (
    tester,
  ) async {
    // The control. If deferral had swallowed the normal path, the test above
    // would still pass and prove nothing.
    final ticks = StreamController<RepoWatchEvent>.broadcast();
    addTearDown(ticks.close);
    var snapshots = 0;

    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_StubGit()),
        repoWatchProvider(_repo).overrideWith((ref) => ticks.stream),
        repoSnapshotProvider(_repo).overrideWith((ref) async {
          snapshots++;
          return RepoSnapshot(
            status: GitStatus(branch: const GitBranchInfo(), files: const []),
            refs: const [],
            pendingOp: PendingOp.none,
            refParseWarnings: const [],
            remotes: const [],
          );
        }),
        refsProvider(_repo).overrideWith((ref) async => const []),
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
    final baseline = snapshots;

    ticks.add(
      RepoWatchEvent(
        at: DateTime.now(),
        mode: WatchMode.eventDriven,
        paths: const {'.git/refs/heads/main'},
      ),
    );
    await tester.pumpAndSettle();

    expect(snapshots, greaterThan(baseline));
  });

  testWidgets('History defers its suppressed tick too', (tester) async {
    // The pop-out and the in-tab History have their own listener and their own
    // tracker marks (a proxied mutation marks the window's tracker via
    // `ProxyCommandExecutor.onMutationCompleted`), so each one has to defer for
    // itself. History's stake is the sharpest: a discarded external commit
    // leaves the walk showing a history that predates it.
    SharedPreferences.setMockInitialValues({});
    final ticks = StreamController<RepoWatchEvent>.broadcast();
    addTearDown(ticks.close);
    var snapshots = 0;
    final tracker = OwnMutationTracker(
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );

    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_StubGit()),
        ownMutationTrackerProvider.overrideWithValue(tracker),
        repoWatchProvider(_repo).overrideWith((ref) => ticks.stream),
        // `refreshAfterMutation` invalidates repoMutationFamilies, which
        // includes this — so a rebuild is the deferred refresh landing.
        repoSnapshotProvider(_repo).overrideWith((ref) async {
          snapshots++;
          return RepoSnapshot(
            status: GitStatus(branch: const GitBranchInfo(), files: const []),
            refs: const [],
            pendingOp: PendingOp.none,
            refParseWarnings: const [],
            remotes: const [],
          );
        }),
        refsProvider.overrideWith((ref, repoPath) async => const <GitRef>[]),
        remotesProvider.overrideWith((ref, repoPath) async => const <String>[]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: HistoryView(repoPath: _repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Warm the observable so an invalidation is visible as a REBUILD.
    final sub = container.listen(repoSnapshotProvider(_repo), (_, _) {});
    addTearDown(sub.close);
    await tester.pumpAndSettle();
    final baseline = snapshots;

    tracker.begin(_repo);
    ticks.add(
      RepoWatchEvent(
        at: DateTime.now(),
        mode: WatchMode.eventDriven,
        paths: const {'.git/refs/heads/main'},
      ),
    );
    await tester.pump();
    expect(snapshots, baseline, reason: 'suppressed while our op is in flight');

    tracker.end(_repo);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(
      snapshots,
      greaterThan(baseline),
      reason:
          "History must replay the tick it held, or an external commit "
          'leaves the walk showing a history that predates it until ⌘R',
    );
  });
}
