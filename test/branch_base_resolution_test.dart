import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branch_workspace_prefs.dart';

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _repo = '/repo';

class _BaseGit extends GitService {
  _BaseGit() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<String?> remoteHead(String repoPath, String remote) async => null;

  @override
  Future<String?> revParse(String repoPath, String rev) async => null;
}

BranchBaseCandidate _ref(String name, String oid) => BranchBaseCandidate(
  refName: name,
  displayName: name
      .replaceFirst('refs/heads/', '')
      .replaceFirst('refs/remotes/', ''),
  oid: oid,
);

void main() {
  test('stored ref wins after commit verification', () async {
    final result = await resolveBranchBase(
      refs: [_ref('refs/heads/main', _a)],
      remotes: const ['origin'],
      currentBranch: 'main',
      headOid: _a,
      storedRefName: 'refs/tags/release',
      forgeDefaultBranch: 'main',
      resolveCommit: (revision) async {
        expect(revision, 'refs/tags/release^{commit}');
        return _b;
      },
      resolveRemoteHead: (_) async => 'refs/remotes/origin/main',
    );
    expect(result.base?.source, BranchBaseSource.user);
    expect(result.base?.refName, 'refs/tags/release');
    expect(result.base?.oid, _b);
  });

  test(
    'missing stored ref remains visible while remote HEAD is used',
    () async {
      final result = await resolveBranchBase(
        refs: [_ref('refs/remotes/origin/trunk', _a)],
        remotes: const ['origin'],
        currentBranch: null,
        headOid: null,
        storedRefName: 'refs/heads/gone',
        forgeDefaultBranch: 'main',
        resolveCommit: (_) async => null,
        resolveRemoteHead: (_) async => 'refs/remotes/origin/trunk',
      );
      expect(result.unavailableStoredRef, 'refs/heads/gone');
      expect(result.base?.source, BranchBaseSource.remoteHead);
      expect(result.base?.displayName, 'origin/trunk');
    },
  );

  test(
    'no remotes skips remote resolver and falls back main then master',
    () async {
      var remoteCalls = 0;
      final result = await resolveBranchBase(
        refs: [_ref('refs/heads/master', _b), _ref('refs/heads/main', _a)],
        remotes: const [],
        currentBranch: 'master',
        headOid: _b,
        storedRefName: null,
        forgeDefaultBranch: null,
        resolveCommit: (_) async => null,
        resolveRemoteHead: (_) async {
          remoteCalls++;
          return null;
        },
      );
      expect(remoteCalls, 0);
      expect(result.base?.source, BranchBaseSource.localMain);
      expect(result.base?.oid, _a);
    },
  );

  test('detached and unborn states are explicit', () async {
    Future<BranchBaseResolution> resolve(String? headOid) => resolveBranchBase(
      refs: const [],
      remotes: const [],
      currentBranch: null,
      headOid: headOid,
      storedRefName: null,
      forgeDefaultBranch: null,
      resolveCommit: (_) async => null,
      resolveRemoteHead: (_) async => null,
    );

    final detached = await resolve(_a);
    expect(detached.base?.source, BranchBaseSource.detachedFallback);
    expect(detached.base?.refName, isNull);
    expect(detached.base?.isFallback, isTrue);
    expect((await resolve(null)).base, isNull);
  });

  test('fallback order prefers remote HEAD, then forge, then main/master', () async {
    var remoteCalls = 0;
    final remote = await resolveBranchBase(
      refs: [
        _ref('refs/remotes/origin/trunk', _a),
        _ref('refs/heads/main', _b),
      ],
      remotes: const ['origin'],
      currentBranch: 'main',
      headOid: _b,
      storedRefName: null,
      forgeDefaultBranch: 'main',
      resolveCommit: (_) async => null,
      resolveRemoteHead: (_) async {
        remoteCalls++;
        return 'refs/remotes/origin/trunk';
      },
    );
    expect(remoteCalls, 1);
    expect(remote.base?.source, BranchBaseSource.remoteHead);
    expect(remote.base?.isFallback, isFalse);

    // Symref tip absent from the snapshot still resolves via rev-parse.
    final missingTip = await resolveBranchBase(
      refs: [_ref('refs/heads/main', _b)],
      remotes: const ['origin'],
      currentBranch: 'main',
      headOid: _b,
      storedRefName: null,
      forgeDefaultBranch: null,
      resolveCommit: (revision) async {
        expect(revision, 'refs/remotes/origin/develop^{commit}');
        return _a;
      },
      resolveRemoteHead: (_) async => 'refs/remotes/origin/develop',
    );
    expect(missingTip.base?.source, BranchBaseSource.remoteHead);
    expect(missingTip.base?.oid, _a);
    expect(missingTip.base?.refName, 'refs/remotes/origin/develop');

    final forge = await resolveBranchBase(
      refs: [_ref('refs/heads/develop', _a), _ref('refs/heads/main', _b)],
      remotes: const ['origin'],
      currentBranch: 'main',
      headOid: _b,
      storedRefName: null,
      forgeDefaultBranch: 'develop',
      resolveCommit: (_) async => null,
      resolveRemoteHead: (_) async => null,
    );
    expect(forge.base?.source, BranchBaseSource.forgeDefault);
    expect(forge.base?.displayName, 'develop');

    final localMain = await resolveBranchBase(
      refs: [_ref('refs/heads/main', _a), _ref('refs/heads/master', _b)],
      remotes: const [],
      currentBranch: 'master',
      headOid: _b,
      storedRefName: null,
      forgeDefaultBranch: null,
      resolveCommit: (_) async => null,
      resolveRemoteHead: (_) async => null,
    );
    expect(localMain.base?.source, BranchBaseSource.localMain);
    expect(localMain.base?.isFallback, isTrue);

    final current = await resolveBranchBase(
      refs: [_ref('refs/heads/work', _a)],
      remotes: const [],
      currentBranch: 'work',
      headOid: _a,
      storedRefName: null,
      forgeDefaultBranch: null,
      resolveCommit: (_) async => null,
      resolveRemoteHead: (_) async => null,
    );
    expect(current.base?.source, BranchBaseSource.currentFallback);
    expect(current.base?.isFallback, isTrue);
  });

  test('automatic resolution never mutates a stored user base preference', () async {
    // resolveBranchBase is pure: it reports unavailableStoredRef but never
    // rewrites the caller's stored selection — only an explicit user choice
    // (or Reset) may change preferences.
    const stored = 'refs/heads/gone';
    final result = await resolveBranchBase(
      refs: [_ref('refs/heads/main', _a)],
      remotes: const [],
      currentBranch: 'main',
      headOid: _a,
      storedRefName: stored,
      forgeDefaultBranch: null,
      resolveCommit: (_) async => null,
      resolveRemoteHead: (_) async => null,
    );
    expect(result.unavailableStoredRef, stored);
    expect(result.base?.source, BranchBaseSource.localMain);
    expect(result.base?.source, isNot(BranchBaseSource.user));
  });

  test('Browse reads passive policy only; Review may populate it', () async {
    var policyFetches = 0;
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_BaseGit()),
        refsProvider(_repo).overrideWith(
          (ref) async => const [
            GitRef(
              name: 'refs/heads/develop',
              oid: _a,
              isHead: false,
              subject: '',
            ),
            GitRef(name: 'refs/heads/work', oid: _b, isHead: true, subject: ''),
          ],
        ),
        remotesProvider(_repo).overrideWith((ref) async => const []),
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'work', oid: _b),
            files: const [],
          ),
        ),
        branchWorkspacePrefsProvider(
          _repo,
        ).overrideWith((ref) async => const BranchWorkspacePrefs()),
        repoMergePolicyProvider(_repo).overrideWith((ref) async {
          policyFetches++;
          return const GhRepoMergePolicy(defaultBranch: 'develop');
        }),
      ],
    );
    addTearDown(container.dispose);

    final browse = await container.read(
      branchBaseProvider((repoPath: _repo, allowForgeFetch: false)).future,
    );
    expect(policyFetches, 0);
    expect(browse.base?.source, BranchBaseSource.currentFallback);

    final review = await container.read(
      branchBaseProvider((repoPath: _repo, allowForgeFetch: true)).future,
    );
    expect(policyFetches, 1);
    expect(review.base?.source, BranchBaseSource.forgeDefault);
    expect(review.base?.displayName, 'develop');

    final passiveBrowse = await container.read(
      branchBaseProvider((repoPath: _repo, allowForgeFetch: false)).future,
    );
    expect(policyFetches, 1);
    expect(passiveBrowse.base?.source, BranchBaseSource.forgeDefault);
  });
}
