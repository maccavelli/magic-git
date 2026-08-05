import 'dart:io';

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

  final List<({String range, int? context, bool ignoreWhitespace})> calls = [];

  @override
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    calls.add((
      range: range,
      context: context,
      ignoreWhitespace: ignoreWhitespace,
    ));
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

    const key = (
      repoPath: _repo,
      baseOid: _base,
      branchOid: _branch,
      context: 3,
      ignoreWhitespace: false,
    );
    final patch = await container.read(branchDiffProvider(key).future);
    expect(patch, contains('diff --git'));
    expect(git.calls.single.range, '$_base...$_branch');
    expect(git.calls.single.context, 3);
    expect(git.calls.single.ignoreWhitespace, isFalse);

    // Different options are a different cache key (provider family args).
    await container.read(
      branchDiffProvider((
        repoPath: _repo,
        baseOid: _base,
        branchOid: _branch,
        context: 10,
        ignoreWhitespace: true,
      )).future,
    );
    expect(git.calls, hasLength(2));
    expect(git.calls.last.context, 10);
    expect(git.calls.last.ignoreWhitespace, isTrue);
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

  test(
    'every KeepAliveLru field is cleared by clearHashKeyedRepoCaches',
    () {
      // §0.5.C structural guard: private LRUs cannot be introspected, so
      // assert source membership. Omitting a new LRU recreates stuck-loading.
      final providers = File('lib/core/providers/app_providers.dart').readAsStringSync();
      final lruDecls = RegExp(
        r'^final (_\w+Lru) = KeepAliveLru',
        multiLine: true,
      ).allMatches(providers).map((m) => m.group(1)!).toList();
      expect(lruDecls, isNotEmpty);

      final clearStart = providers.indexOf('void clearHashKeyedRepoCaches()');
      expect(clearStart, greaterThanOrEqualTo(0));
      final clearEnd = providers.indexOf('\n}', clearStart);
      final clearBody = providers.substring(clearStart, clearEnd);

      for (final name in lruDecls) {
        expect(
          clearBody,
          contains('$name.clear()'),
          reason: '$name must be cleared in clearHashKeyedRepoCaches',
        );
      }
      expect(clearBody, contains('_branchDiffLru.clear()'));
    },
  );

  test('phase-2 comparison families are in repoScopedFetchFamilies', () {
    final providers = File('lib/core/providers/app_providers.dart').readAsStringSync();
    final start = providers.indexOf('final List<ProviderOrFamily> repoScopedFetchFamilies');
    expect(start, greaterThanOrEqualTo(0));
    final end = providers.indexOf('];', start);
    final body = providers.substring(start, end);
    expect(body, contains('branchUniqueCommitsProvider'));
    expect(body, contains('branchComparisonMetadataProvider'));
    expect(body, contains('branchDiffProvider'));
    expect(body, contains('mergePreviewCapabilityProvider'));
    expect(body, contains('branchMergePreviewProvider'));
  });
}
