// The Repository panel is the app's only consumer of repoWatchProvider, so its
// listener is what turns filesystem ticks into provider refreshes for EVERY
// panel (History, Branches, … stay mounted in the IndexedStack and watch the
// shared families). July 2026 repository-tab pass, pinning three behaviors:
//
//  * a git-state tick (a commit/checkout made in a terminal) invalidates the
//    mutation families even while the Repository page is HIDDEN — the user
//    sitting on History must see the external commit now, not after a detour
//    through the Repository tab;
//  * an unscoped tick that arrives while hidden defers one full family
//    re-sync to the next activation (instead of a status-only re-sync that
//    can't reveal moved git state);
//  * a HEAD move observed between two landed statuses — the only signal
//    polling mode gets — invalidates the families, suppressed when it is the
//    echo of this app's own mutation.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

const _repo = '/srv/repo';

GitStatus _statusAt(String oid) => GitStatus(
  branch: GitBranchInfo(oid: oid, head: 'main'),
  files: const [],
);

class _HiddenFileView extends FileViewVisibility {
  @override
  bool build() => false;
}

class _StubConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(backend: ConnectionBackend.ssh);
}

/// Harness: RepoStatusView over a mutable status, a test-driven watch stream,
/// and a fetch-counting logProvider held alive as the families probe —
/// invalidating an unwatched autoDispose provider is a no-op, so the count
/// only moves when the panel genuinely invalidated the mutation set.
class _Harness {
  final ProviderContainer container;
  final StreamController<RepoWatchEvent> watch;
  GitStatus current;
  int logFetches = 0;
  int statusFetches = 0;

  _Harness._(this.container, this.watch, this.current);

  static _Harness create(GitStatus initial) {
    final watch = StreamController<RepoWatchEvent>.broadcast();
    late final _Harness h;
    final container = ProviderContainer(
      overrides: [
        statusProvider(_repo).overrideWith((ref) async {
          h.statusFetches++;
          return h.current;
        }),
        logProvider(_repo).overrideWith((ref) async {
          h.logFetches++;
          return const <GitCommit>[];
        }),
        pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
        repoWatchProvider(_repo).overrideWith((ref) => watch.stream),
        fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
        refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
        remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        connectionProvider.overrideWith(_StubConnection.new),
      ],
    );
    h = _Harness._(container, watch, initial);
    // Keep the probe provider mounted, like the History panel would.
    container.listen(logProvider(_repo), (_, _) {});
    addTearDown(() {
      // Dispose FIRST: it cancels the repoWatchProvider subscription, so the
      // controller's close completes trivially. Awaiting close() with the
      // subscription still live deadlocks under the test's fake-async zone.
      container.dispose();
      unawaited(watch.close());
    });
    return h;
  }

  Future<void> pump(WidgetTester tester, {required bool isActive}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: RepoStatusView(repoPath: _repo, isActive: isActive),
        ),
      ),
    );
    await settle(tester);
  }

  static Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();

  Future<void> tick(WidgetTester tester, Set<String> paths) async {
    watch.add(
      RepoWatchEvent(
        at: DateTime.now(),
        mode: WatchMode.eventDriven,
        paths: paths,
      ),
    );
    await settle(tester);
  }
}

void main() {
  testWidgets(
    'a git-state tick invalidates the mutation families even while the page '
    'is hidden',
    (tester) async {
      final h = _Harness.create(_statusAt('aaa'));
      await h.pump(tester, isActive: false);
      final logBefore = h.logFetches;

      await h.tick(tester, {'.git/HEAD'});

      expect(
        h.logFetches,
        logBefore + 1,
        reason:
            'an external commit must reach the mounted History/Branches '
            'panels immediately, not wait for a Repository-tab visit',
      );
    },
  );

  testWidgets('an unscoped tick while hidden defers one full family re-sync to '
      'activation', (tester) async {
    final h = _Harness.create(_statusAt('aaa'));
    await h.pump(tester, isActive: false);
    final logBefore = h.logFetches;

    // Unscoped (watcher restart / overflowing burst): too blunt to act on
    // repeatedly in the background.
    await h.tick(tester, const {});
    expect(h.logFetches, logBefore);

    // Activation runs the widened re-sync: the whole mutation set, since
    // the blind tick may have hidden git-state changes.
    await h.pump(tester, isActive: true);
    expect(h.logFetches, logBefore + 1);
  });

  testWidgets('a quiet hidden spell re-syncs only status on activation', (
    tester,
  ) async {
    final h = _Harness.create(_statusAt('aaa'));
    await h.pump(tester, isActive: false);
    final logBefore = h.logFetches;
    final statusBefore = h.statusFetches;

    await h.pump(tester, isActive: true);

    expect(h.statusFetches, statusBefore + 1);
    expect(h.logFetches, logBefore, reason: 'no git-state signal, no walk');
  });

  testWidgets('a HEAD move between landed statuses invalidates the families '
      '(polling-mode external commit)', (tester) async {
    final h = _Harness.create(_statusAt('aaa'));
    await h.pump(tester, isActive: true);
    final logBefore = h.logFetches;

    // A polling tick can only refetch status; the moved oid it lands is the
    // one signal an external commit leaves in that mode.
    h.current = _statusAt('bbb');
    h.container.invalidate(statusProvider(_repo));
    await _Harness.settle(tester);

    expect(h.logFetches, logBefore + 1);

    // The refetch the detection itself triggered landed with the same oid —
    // no second round.
    await _Harness.settle(tester);
    expect(h.logFetches, logBefore + 1);
  });

  testWidgets(
    'a HEAD move within the own-mutation window is the echo of our own '
    'commit — no second refresh',
    (tester) async {
      final h = _Harness.create(_statusAt('aaa'));
      await h.pump(tester, isActive: true);
      final logBefore = h.logFetches;

      // What refreshAfterMutation does (e.g. the commit dialog committing):
      // mark, then the status refetch lands with the new oid.
      h.container.read(ownMutationTrackerProvider).mark(_repo);
      h.current = _statusAt('bbb');
      h.container.invalidate(statusProvider(_repo));
      await _Harness.settle(tester);

      expect(h.logFetches, logBefore);
    },
  );
}
