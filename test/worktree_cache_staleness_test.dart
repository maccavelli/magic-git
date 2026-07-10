// Worktree-dependent caches (file diffs, untracked previews, conflict
// content, blame) follow the repo's landed status: a status refresh that
// lands *changed* content — the signal that the working tree changed —
// invalidates them, so a kept-alive cache entry can never serve stale
// content after an external edit. A refresh that found nothing changed
// hands back the previous status instance (statusProvider's content-identity
// memo) and leaves every cache intact — a watcher tick on an idle repo must
// not refetch the world. Commit (hash-keyed) caches deliberately do NOT
// follow status: a commit's patch is immutable.

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

  @override
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    diffCalls++;
    return 'diff v$diffCalls';
  }

  @override
  Future<String> showCommit(String repoPath, String hash, {String? path}) async {
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

  test('a commit patch cache is immutable — status refreshes never touch it',
      () async {
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    const repo = '/repo-staleness-b';
    const key = (repo, 'abc123');

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
