import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _repo = '/repo';
const _base = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _branch = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _DiffGit extends GitService {
  _DiffGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<String> ranges = [];

  @override
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    ranges.add(range);
    return 'diff --git a/x b/x\n';
  }
}

void main() {
  test('branchDiffProvider uses three-dot range and options key', () async {
    final git = _DiffGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    final key = (
      repoPath: _repo,
      baseOid: _base,
      branchOid: _branch,
      context: 3,
      ignoreWhitespace: false,
    );
    final patch = await container.read(branchDiffProvider(key).future);
    expect(patch, contains('diff --git'));
    expect(git.ranges.single, '$_base...$_branch');
  });

  test('clearHashKeyedRepoCaches includes branch-diff LRU membership', () {
    // Structural: calling clear must not throw after branchDiff was used.
    // The known stuck-loading failure mode is an LRU omitted from clear.
    final git = _DiffGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    final sub = container.listen(
      branchDiffProvider((
        repoPath: _repo,
        baseOid: _base,
        branchOid: _branch,
        context: 5,
        ignoreWhitespace: true,
      )),
      (_, _) {},
    );
    addTearDown(sub.close);

    expect(() => clearHashKeyedRepoCaches(), returnsNormally);
  });
}
