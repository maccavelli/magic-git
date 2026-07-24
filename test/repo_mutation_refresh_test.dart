// After a mutation, every surface that reads repo state must re-read it.
//
// The regression this pins: History reads `logSearchProvider` (it has since the
// paged/searchable log landed), but the post-mutation refresh paths still named
// `logProvider` — a provider nothing but the Dashboard reads any more. So a
// commit made from the Repository panel refreshed `refsProvider` and left the
// History list on the pre-commit walk. The branch/HEAD chip then pointed at a
// commit that was not in the list, so it had no row to land on and vanished
// entirely — and only ⌘R *inside* History (which goes through the shared
// [repoMutationFamilies] set, the one that is correct) brought it back.
//
// The real defect is the duplication: seven call sites hand-rolled their own
// idea of "the repo changed" instead of using the one definition. So the guard
// below is not "History refetches" — it is "nobody hand-rolls this set".

import 'dart:io';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/repo_tree.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

const _repo = '/srv/repo';

/// The unfiltered HEAD walk — the key History builds with no filters typed.
const LogQuery _historyQuery = (
  repoPath: _repo,
  grep: null,
  author: null,
  since: null,
  until: null,
  path: null,
  sha: null,
  noMerges: false,
  all: false,
);

class _CountingGit extends GitService {
  _CountingGit() : super(SSHCommandExecutor(SSHClientManager()));

  /// How many times the History panel's walk has actually been run.
  int logCalls = 0;
  final List<String> staged = [];

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
  }) async {
    logCalls++;
    return const [
      GitCommit(
        hash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        shortHash: 'aaaaaaa',
        authorName: 'Dev',
        authorEmail: 'd@e',
        date: '2026-07-13T10:00',
        parents: [],
        subject: 'only commit',
      ),
    ];
  }

  @override
  Future<void> stage(String repoPath, String path) async {
    staged.add(path);
  }
}

GitStatus _oneModifiedFile() => GitStatus(
  branch: const GitBranchInfo(),
  files: const [GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M')],
);

void main() {
  testWidgets('a mutation refreshes the log History actually reads', (
    tester,
  ) async {
    // The panel's toolbar needs a real desktop width; the 800x600 default
    // overflows it and the overflow is reported as a test failure.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final git = _CountingGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        statusProvider(_repo).overrideWith((ref) async => _oneModifiedFile()),
        pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
        repoWatchProvider(
          _repo,
        ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
        // Sibling of the refs override: the views now read CONFIGURED
        // remotes (remotesProvider), not remote-tracking refs.
        remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        // Follows statusProvider, so the refresh re-drives it too; stub it or
        // its read reaches the fake's unconfigured executor and leaves the
        // retry backoff timer pending past teardown.
        repoStructureProvider(_repo).overrideWith(
          (ref) async =>
              const RepoNode(name: '', path: '', isDir: true, children: []),
        ),
        connectionProvider.overrideWith(
          () => _StubConnection(
            const ConnectionState(backend: ConnectionBackend.ssh),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // History is open on another tab, holding its walk — exactly the situation
    // where a stale list is invisible until you look at it.
    final history = container.listen(
      logSearchProvider(_historyQuery),
      (_, _) {},
    );

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

    expect(history.read().value, isNotNull, reason: 'the walk ran once');
    expect(git.logCalls, 1);

    // Stage a hunk-worth of work: an ordinary mutation through the panel's real
    // refresh path.
    await tester.tap(_icon(CupertinoIcons.plus_circle));
    await tester.pumpAndSettle();
    expect(git.staged, ['lib/a.dart'], reason: 'the mutation ran');

    expect(
      git.logCalls,
      2,
      reason: 'the repo changed, so the log History reads must be re-walked — '
          'refreshing the retired `logProvider` instead leaves History showing '
          'a pre-mutation list',
    );
  });

  test('a mutation in a linked worktree refreshes the SHARED state of every '
      'other worktree, but not their private working trees', () async {
    // Worktrees of one repo share objects, refs, the stash and the reflog (all
    // in the common git dir); only the working tree, index and HEAD are
    // private. So committing in a worktree moves a branch the MAIN repo's
    // Branches panel is showing — under a repoPath the mutating site never
    // sees. Shared state therefore goes into the set as whole families.
    const main = '/srv/repo';
    const worktree = '/srv/repo-feat';

    final refsReads = <String>[];
    final statusReads = <String>[];

    final container = ProviderContainer(
      overrides: [
        for (final repo in const [main, worktree]) ...[
          refsProvider(repo).overrideWith((ref) async {
            refsReads.add(repo);
            return const <GitRef>[];
          }),
          statusProvider(repo).overrideWith((ref) async {
            statusReads.add(repo);
            return GitStatus(branch: const GitBranchInfo(), files: const []);
          }),
        ],
      ],
    );
    addTearDown(container.dispose);

    // Both worktrees are open and have read their state once.
    for (final repo in const [main, worktree]) {
      container.listen(refsProvider(repo), (_, _) {});
      container.listen(statusProvider(repo), (_, _) {});
    }
    expect(refsReads, [main, worktree]);
    expect(statusReads, [main, worktree]);
    refsReads.clear();
    statusReads.clear();

    // Something commits INSIDE the linked worktree.
    for (final p in repoMutationFamilies(worktree)) {
      container.invalidate(p);
    }
    // Riverpod recomputes an invalidated provider on the next microtask, not
    // synchronously — let the scheduler run before asserting who re-read.
    await Future<void>.delayed(Duration.zero);

    // Refs are shared, so BOTH must re-read — the main repo's Branches panel
    // would otherwise show a stale tip for a branch that just moved.
    expect(
      refsReads,
      containsAll(const [main, worktree]),
      reason: 'refs live in the common git dir and are shared by every '
          'worktree, so a commit in one moves a branch every other is showing',
    );

    // The working tree is private, so only the worktree that changed re-reads.
    // Re-running the main repo's status would be pure waste.
    expect(
      statusReads,
      const [worktree],
      reason: "each worktree has its own index and working tree — committing "
          "in one does not touch another's file list",
    );
  });

  test('no feature hand-rolls the post-mutation invalidation set', () {
    // One definition of "the repo changed", used by everyone. A site that lists
    // the providers itself will always drift: it did, silently, the moment
    // History swapped `logProvider` for `logSearchProvider`.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The set itself is defined here, and the Dashboard legitimately reads
      // (never invalidates) the plain logProvider.
      if (entity.path.endsWith('app_providers.dart')) continue;
      final source = entity.readAsStringSync();
      // `statusProvider` alone is deliberately NOT here: refreshing just the
      // file list is a legitimate, narrower thing (a file created or deleted in
      // the file browser, a watcher tick that touched only the working tree).
      // These are the git-state reads — naming any one of them at a call site is
      // that site claiming "git's state moved", and that claim is exactly the
      // one the shared set exists to answer completely.
      for (final family in const [
        'logProvider',
        'logSearchProvider',
        'refsProvider',
        'stashesProvider',
        'reflogProvider',
        'magicSnapshotsProvider',
        // Shared by every worktree of a repo: `worktree add/remove` run from
        // any one of them rewrites `<common>/.git/worktrees/`, so a site that
        // refreshed only its own repoPath would leave every other worktree's
        // list stale.
        'gitWorktreesProvider',
      ]) {
        if (source.contains('invalidate($family(')) {
          offenders.add('${entity.path}: invalidate($family(…))');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these sites must invalidate repoMutationFamilies(repoPath) instead:\n'
          '${offenders.join('\n')}',
    );
  });
}

Finder _icon(IconData d) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == d);

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}
