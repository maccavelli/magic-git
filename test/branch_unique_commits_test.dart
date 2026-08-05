import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _repo = '/repo';
const _base = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _branch = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _LogGit extends GitService {
  _LogGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<({String revision, int maxCount, int skip})> calls = [];
  List<GitCommit> Function({required int skip, required int maxCount})?
  handler;

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
    calls.add((revision: revision, maxCount: maxCount, skip: skip));
    return handler?.call(skip: skip, maxCount: maxCount) ?? const [];
  }
}

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'A',
  authorEmail: 'a@a',
  date: '2020-01-01T00:00:00Z',
  parents: const [],
  subject: subject,
);

void main() {
  test('unique commits use base..branch after end-of-options semantics', () async {
    final git = _LogGit();
    git.handler = ({required skip, required maxCount}) => [
      for (var i = skip; i < skip + maxCount; i++)
        _c('${i.toRadixString(16).padLeft(40, '0')}', 'c$i'),
    ];
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    final key = (repoPath: _repo, baseOid: _base, branchOid: _branch);
    final first = await container.read(branchUniqueCommitsProvider(key).future);
    expect(first, hasLength(kBranchUniqueCommitsPageSize));
    expect(git.calls.single.revision, '$_base..$_branch');
    expect(git.calls.single.maxCount, kBranchUniqueCommitsPageSize);
    expect(git.calls.single.skip, 0);

    final notifier = container.read(branchUniqueCommitsProvider(key).notifier);
    await notifier.loadMore();
    expect(git.calls, hasLength(2));
    expect(git.calls.last.skip, kBranchUniqueCommitsPageSize);
    expect(git.calls.last.maxCount, kBranchUniqueCommitsPageSize);
    // Growing max-count must not replace skip-based paging.
    expect(git.calls.last.maxCount, isNot(100));

    final all = container.read(branchUniqueCommitsProvider(key)).value!;
    expect(all, hasLength(kBranchUniqueCommitsPageSize * 2));
  });

  test('full first page then failed loadMore keeps rows', () async {
    final git = _LogGit();
    var page = 0;
    git.handler = ({required skip, required maxCount}) {
      page++;
      if (page == 1) {
        return [
          for (var i = 0; i < maxCount; i++)
            _c('${i.toString().padLeft(40, 'f')}', 'p$i'),
        ];
      }
      throw StateError('network');
    };
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    final key = (repoPath: _repo, baseOid: _base, branchOid: _branch);
    final first = await container.read(branchUniqueCommitsProvider(key).future);
    expect(first, hasLength(kBranchUniqueCommitsPageSize));
    final notifier = container.read(branchUniqueCommitsProvider(key).notifier);
    expect(notifier.exhausted, isFalse);

    await notifier.loadMore();
    expect(notifier.pageFailed, isTrue);
    expect(
      container.read(branchUniqueCommitsProvider(key)).value,
      hasLength(kBranchUniqueCommitsPageSize),
    );
  });
}
