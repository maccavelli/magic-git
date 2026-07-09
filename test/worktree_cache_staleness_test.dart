// Worktree-dependent caches (file diffs, untracked previews, conflict
// content, blame) follow the repo's landed status: a status refresh — the
// signal that the working tree changed — invalidates them, so a kept-alive
// cache entry can never serve stale content after an external edit. Commit
// (hash-keyed) caches deliberately do NOT follow status: a commit's patch is
// immutable.

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

  @override
  Future<GitStatus> status(String repoPath) async {
    statusCalls++;
    // A fresh instance per call — exactly what a real refresh produces.
    return GitStatus(branch: const GitBranchInfo(), files: const []);
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

    // A watcher tick / mutation refresh: status invalidated and re-landed.
    container.invalidate(statusProvider(repo));
    await container.read(statusProvider(repo).future);
    await Future<void>.delayed(Duration.zero); // let invalidation propagate

    expect(
      await container.read(fileDiffProvider(key).future),
      'diff v2',
      reason: 'the cached diff must refetch once fresh status lands',
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
