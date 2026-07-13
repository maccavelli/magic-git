// Worktree-dependent caches (file diffs, untracked previews, conflict
// content, blame) follow the repo's landed status: a status refresh that
// lands *changed* content — the signal that the working tree changed —
// invalidates them, so a kept-alive cache entry can never serve stale
// content after an external edit. A refresh that found nothing changed
// hands back the previous status instance (statusProvider's content-identity
// memo) and leaves every cache intact — a watcher tick on an idle repo must
// not refetch the world. Commit (hash-keyed) caches deliberately do NOT
// follow status: a commit's patch is immutable.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';

class _FakeGit extends GitService {
  _FakeGit() : super(LocalCommandExecutor());

  int statusCalls = 0;
  int diffCalls = 0;
  int showCalls = 0;

  /// The worktree state each status() call reports — change it to model an
  /// actual repo change; leave it to model an idle-repo watcher tick.
  String oid = 'oid-initial';

  @override
  Future<GitStatus> status(String repoPath) async {
    statusCalls++;
    // A fresh instance per call — exactly what a real refresh produces.
    return GitStatus(branch: GitBranchInfo(oid: oid), files: const []);
  }

  /// When set, every diffFile call parks on a fresh completer the test finishes
  /// by hand — so a fetch can be held *in flight* while status changes land.
  final List<Completer<String>> pendingDiffs = [];
  bool gateDiffs = false;

  @override
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) {
    diffCalls++;
    if (!gateDiffs) return Future.value('diff v$diffCalls');
    final completer = Completer<String>();
    pendingDiffs.add(completer);
    return completer.future;
  }

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async {
    showCalls++;
    return 'patch v$showCalls';
  }
}

void main() {
  test('a landed status refresh invalidates a cached worktree diff', () async {
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    const repo = '/repo-staleness-a';
    const key = (repo, 'lib/a.dart', false, false, 3);

    // Mirror the app: the status list is always watched (repo status view),
    // and lands before a diff pane is opened from it.
    final statusSub = container.listen(statusProvider(repo), (_, _) {});
    addTearDown(statusSub.close);
    await container.read(statusProvider(repo).future);

    final diffSub = container.listen(fileDiffProvider(key), (_, _) {});
    addTearDown(diffSub.close);
    expect(await container.read(fileDiffProvider(key).future), 'diff v1');
    // Re-reading without any status change serves the cache — no refetch.
    expect(await container.read(fileDiffProvider(key).future), 'diff v1');
    expect(git.diffCalls, 1);

    // An idle-repo watcher tick: status refetched, identical content lands.
    // The content-identity memo hands back the previous instance — the
    // cached diff must survive untouched.
    container.invalidate(statusProvider(repo));
    await container.read(statusProvider(repo).future);
    await Future<void>.delayed(Duration.zero);
    expect(
      await container.read(fileDiffProvider(key).future),
      'diff v1',
      reason: 'a no-change status refresh must not evict cached diffs',
    );
    expect(git.diffCalls, 1);

    // A real external change: the re-landed status differs → invalidate.
    git.oid = 'oid-after-edit';
    container.invalidate(statusProvider(repo));
    await container.read(statusProvider(repo).future);
    await Future<void>.delayed(Duration.zero); // let invalidation propagate

    expect(
      await container.read(fileDiffProvider(key).future),
      'diff v2',
      reason: 'the cached diff must refetch once changed status lands',
    );
    expect(git.diffCalls, 2);
  });

  test('worktree changes never restart a fetch that is still in flight',
      () async {
    // The regression: a status change used to invalidate a diff whose *first*
    // fetch had not landed yet. That doesn't refresh anything — it throws the
    // in-flight read away and starts over from a bare AsyncLoading, because
    // there is no previous value for Riverpod to carry through the refresh. So
    // the pane falls back to a spinner; and when the next change arrives before
    // the restarted read finishes, that one is thrown away too. A repo that
    // changes faster than a diff takes to fetch therefore never showed a diff
    // at all — it span forever. (Writes into a gitignored build directory are
    // enough to drive it: every filesystem event mints a new status, whether or
    // not git can see the file that changed.)
    final git = _FakeGit()..gateDiffs = true;
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    const repo = '/repo-staleness-c';
    const key = (repo, 'lib/a.dart', false, false, 3);

    final statusSub = container.listen(statusProvider(repo), (_, _) {});
    addTearDown(statusSub.close);
    await container.read(statusProvider(repo).future);

    // The user opens the diff: one fetch, held in flight.
    final diffSub = container.listen(fileDiffProvider(key), (_, _) {});
    addTearDown(diffSub.close);
    await Future<void>.delayed(Duration.zero);
    expect(git.pendingDiffs, hasLength(1));

    // Three worktree changes land while that first read is still running.
    for (final oid in ['edit-1', 'edit-2', 'edit-3']) {
      git.oid = oid;
      container.invalidate(statusProvider(repo));
      await container.read(statusProvider(repo).future);
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      git.pendingDiffs,
      hasLength(1),
      reason: 'the in-flight read must be left alone — restarting it on every '
          'change is what starved it forever',
    );

    // It lands, and the value is actually published (not torn down first).
    git.pendingDiffs.first.complete('diff v1');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(fileDiffProvider(key)).value, 'diff v1');

    // The changes that arrived mid-flight are not lost: they coalesce into
    // exactly one follow-up read, which refreshes behind the value on screen.
    await Future<void>.delayed(Duration.zero);
    expect(
      git.pendingDiffs,
      hasLength(2),
      reason: 'three mid-flight changes must collapse to one refetch, not three',
    );
    // Riverpod carries the previous value through that refresh, so the pane
    // keeps showing the diff rather than dropping back to a spinner.
    expect(container.read(fileDiffProvider(key)).value, 'diff v1');

    git.pendingDiffs.last.complete('diff v2');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(fileDiffProvider(key)).value, 'diff v2');
  });

  test('an edit to one file leaves every other file\'s cache alone', () async {
    // The invalidation is per path. It used to be per repo: any filesystem
    // event refetched every cached diff, blame, conflict and untracked preview
    // in the repository, so editing one file re-read all of them — and a build
    // touching files git does not even track re-read all of them, repeatedly.
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    const repo = '/repo-staleness-d';
    const edited = (repo, 'lib/edited.dart', false, false, 3);
    const untouched = (repo, 'lib/untouched.dart', false, false, 3);

    final statusSub = container.listen(statusProvider(repo), (_, _) {});
    addTearDown(statusSub.close);
    await container.read(statusProvider(repo).future);

    final a = container.listen(fileDiffProvider(edited), (_, _) {});
    final b = container.listen(fileDiffProvider(untouched), (_, _) {});
    addTearDown(a.close);
    addTearDown(b.close);
    await container.read(fileDiffProvider(edited).future);
    await container.read(fileDiffProvider(untouched).future);
    final fetchesBefore = git.diffCalls;

    // A content-only edit to one of them: same status records, different bytes.
    container
        .read(worktreeEditsProvider.notifier)
        .noteFiles(repo, const ['lib/edited.dart']);
    await Future<void>.delayed(Duration.zero);
    await container.read(fileDiffProvider(edited).future);
    await container.read(fileDiffProvider(untouched).future);

    expect(
      git.diffCalls,
      fetchesBefore + 1,
      reason: 'exactly one refetch: the file that was edited, and nothing else',
    );
  });

  test('a move in git\'s own state refreshes every file', () async {
    // An `git add -p` in a terminal rewrites the index while leaving both the
    // file on disk and its porcelain record untouched — and yet every staged
    // diff may now be different. A path-scoped signal cannot express that, so a
    // `.git/` tick is deliberately repo-wide.
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    const repo = '/repo-staleness-e';
    const key = (repo, 'lib/a.dart', true, false, 3); // the *staged* diff

    final statusSub = container.listen(statusProvider(repo), (_, _) {});
    addTearDown(statusSub.close);
    await container.read(statusProvider(repo).future);
    final sub = container.listen(fileDiffProvider(key), (_, _) {});
    addTearDown(sub.close);
    await container.read(fileDiffProvider(key).future);
    final before = git.diffCalls;

    container.read(worktreeEditsProvider.notifier).noteRepo(repo);
    await Future<void>.delayed(Duration.zero);
    await container.read(fileDiffProvider(key).future);

    expect(git.diffCalls, before + 1);
  });

  test('a commit patch cache is immutable — status refreshes never touch it',
      () async {
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    const repo = '/repo-staleness-b';
    const key = (repo, 'abc123', 3);

    expect(await container.read(commitDiffProvider(key).future), 'patch v1');
    await container.read(statusProvider(repo).future);
    container.invalidate(statusProvider(repo));
    await container.read(statusProvider(repo).future);
    await Future<void>.delayed(Duration.zero);

    expect(
      await container.read(commitDiffProvider(key).future),
      'patch v1',
      reason: 'hash-keyed content never refetches on a status change',
    );
    expect(git.showCalls, 1);
  });
}
