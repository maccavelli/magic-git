// The Branches detail's RECENT COMMITS preview must not go stale.
//
// branchCommitsProvider is keyed by branch *name*, which is stable across a
// tip move, and it sits in neither refresh family — so a commit/merge/rebase
// on the selected branch would leave the preview on pre-mutation history until
// the branch was reselected, and ⌘R wouldn't fix it. The fix makes it depend
// on refsProvider (invalidated by every mutation + the watcher), so it rides
// that refresh. This pins that dependency.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _repo = '/srv/repo';

class _CountingGit extends GitService {
  _CountingGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<String> logRevisions = [];

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
  }) async {
    logRevisions.add(revision);
    return const <GitCommit>[];
  }
}

void main() {
  test(
    'branchCommitsProvider re-fetches when the repo\'s refs change',
    () async {
      final git = _CountingGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
        ],
      );
      addTearDown(container.dispose);

      // Keep the preview subscribed so autoDispose doesn't tear it down between
      // reads (a fresh instance would fetch again for the wrong reason).
      final sub = container.listen(
        branchCommitsProvider((_repo, 'feature')),
        (_, _) {},
      );
      addTearDown(sub.close);

      // Fully settle the initial load (refs resolves loading→data, which itself
      // re-triggers the watcher — so the exact count here isn't the point).
      await container.read(refsProvider(_repo).future);
      await container.read(branchCommitsProvider((_repo, 'feature')).future);
      await Future<void>.delayed(Duration.zero);
      final before = git.logRevisions.length;
      expect(before, greaterThanOrEqualTo(1), reason: 'initial preview fetch');
      expect(git.logRevisions, everyElement('feature'));

      // A mutation on this repo invalidates refsProvider; the preview must ride
      // that and re-walk, not stay on the pre-mutation history.
      container.invalidate(refsProvider(_repo));
      await container.read(refsProvider(_repo).future);
      await container.read(branchCommitsProvider((_repo, 'feature')).future);
      await Future<void>.delayed(Duration.zero);

      expect(
        git.logRevisions.length,
        greaterThan(before),
        reason: 'refs invalidation must re-fetch the branch preview',
      );
    },
  );
}
