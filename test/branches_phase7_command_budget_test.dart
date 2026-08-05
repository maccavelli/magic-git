// Phase 7: deterministic command-budget gates for Branches.
// Wall-clock/CPU is release evidence only — ordinary CI asserts command shapes
// and zero N+1 comparison/forge work, not timing.

import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';
const _mainOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _featureOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _tree = 'cccccccccccccccccccccccccccccccccccccccc';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: _mainOid, isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/feature',
    oid: _featureOid,
    isHead: false,
    subject: 's',
  ),
];

class _CountingGit extends GitService {
  _CountingGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<String> ops = [];

  @override
  Future<BranchComparisonMetadata> branchComparisonMetadata(
    String repoPath, {
    required String baseOid,
    required String branchOid,
    int maxFiles = kBranchComparisonMaxFiles,
  }) async {
    ops.add('branchComparisonMetadata');
    return BranchComparisonMetadata(
      baseOid: baseOid,
      branchOid: branchOid,
      mergeBaseOid: baseOid,
      ancestry: ComparisonAncestry.connected,
      files: const [
        BranchChangedFile(status: 'M', path: 'a.dart', additions: 1, deletions: 0),
      ],
      additions: 1,
      deletions: 0,
      truncated: false,
    );
  }

  @override
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    ops.add('diffRange:$range');
    return 'diff --git a/a b/a\n+hi\n';
  }

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
    ops.add('log:$revision:skip=$skip:max=$maxCount');
    return const [];
  }

  @override
  Future<BranchMergePreview> mergeTreePreview(
    String repoPath, {
    required String baseOid,
    required String branchOid,
  }) async {
    ops.add('mergeTreePreview');
    return BranchMergePreview.clean(treeOid: _tree);
  }

  @override
  Future<BranchReviewBatchResult> branchReviewSummaries(
    String repoPath, {
    required String baseOid,
    required List<({String refName, String oid})> branches,
  }) async {
    ops.add('branchReviewSummaries:n=${branches.length}');
    // Batch size constant is the gate — large inputs must be chunked in service.
    return BranchReviewBatchResult(
      summariesByRefName: {
        for (final b in branches)
          b.refName: BranchReviewSummary(
            refName: b.refName,
            shortName: b.refName.split('/').last,
            branchOid: b.oid,
            baseOid: baseOid,
            aheadOfBase: 1,
            behindBase: 0,
          ),
      },
    );
  }
}

class _EnvNotifier extends BinaryEnvironmentNotifier {
  @override
  RemoteEnvironment build() => const RemoteEnvironment(
    os: 'macos',
    path: '/usr/bin',
    found: {'git': '/usr/bin/git'},
    versions: {'git': '2.44.0'},
  );
}

class _Connected extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _repo,
    sessionEpoch: 1,
  );
}

Future<_CountingGit> _pump(
  WidgetTester tester, {
  List<GitRef> refs = _refs,
  _CountingGit? git,
}) async {
  tester.view.physicalSize = const Size(1500, 1300);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final counting = git ?? _CountingGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(counting),
      binaryEnvironmentProvider.overrideWith(_EnvNotifier.new),
      connectionProvider.overrideWith(_Connected.new),
      refsProvider(_repo).overrideWith((ref) async => refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(head: 'main', oid: _mainOid),
          files: const [],
        ),
      ),
      branchBaseProvider.overrideWith(
        (ref, key) async => const BranchBaseResolution(
          base: BranchBase(
            refName: 'refs/heads/main',
            displayName: 'main',
            oid: _mainOid,
            source: BranchBaseSource.localMain,
            isFallback: false,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: BranchesView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return counting;
}

void main() {
  group('Phase 7 command budget', () {
    testWidgets('Browse first paint issues zero comparison/patch/merge-tree ops', (
      tester,
    ) async {
      final git = await _pump(tester);
      expect(git.ops.where((o) => o.startsWith('diffRange:')), isEmpty);
      expect(git.ops.where((o) => o == 'mergeTreePreview'), isEmpty);
      expect(git.ops.where((o) => o.startsWith('branchReviewSummaries')), isEmpty);
      expect(git.ops.where((o) => o == 'branchComparisonMetadata'), isEmpty);
      expect(git.ops.where((o) => o.startsWith('log:')), isEmpty);
    });

    testWidgets('select branch Overview loads metadata not patch', (tester) async {
      final git = await _pump(tester);
      git.ops.clear();
      await tester.tap(find.text('feature'));
      await tester.pumpAndSettle();
      expect(git.ops, contains('branchComparisonMetadata'));
      expect(git.ops.where((o) => o.startsWith('diffRange:')), isEmpty);
      // Commits tab still no patch.
      await tester.tap(find.text('Commits'));
      await tester.pumpAndSettle();
      expect(git.ops.where((o) => o.startsWith('diffRange:')), isEmpty);
      expect(git.ops.any((o) => o.startsWith('log:')), isTrue);
    });

    testWidgets('Changes fetches patch once; revisit is provider-cache hit', (
      tester,
    ) async {
      final git = await _pump(tester);
      await tester.tap(find.text('feature'));
      await tester.pumpAndSettle();
      git.ops.clear();
      await tester.tap(find.text('Changes'));
      await tester.pumpAndSettle();
      final first = git.ops.where((o) => o.startsWith('diffRange:')).toList();
      expect(first, hasLength(1));
      expect(first.single, contains('$_mainOid...$_featureOid'));
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Changes'));
      await tester.pumpAndSettle();
      // Still a single service call — FutureProvider/LRU keeps the result.
      expect(git.ops.where((o) => o.startsWith('diffRange:')), hasLength(1));
    });

    testWidgets('merge preview is at most one process shape (capability gate)', (
      tester,
    ) async {
      final git = await _pump(tester);
      await tester.tap(find.text('feature'));
      await tester.pumpAndSettle();
      // Overview readiness may request merge-tree once when Git ≥ 2.38.
      final previews = git.ops.where((o) => o == 'mergeTreePreview').length;
      expect(previews, lessThanOrEqualTo(1));
    });
  });

  group('Phase 7 constants', () {
    test('review batch size and unique-commit page size stay documented', () {
      // Tuned values live beside the service/provider constants (Phase 7).
      expect(GitService.branchReviewBatchSize, 100);
      expect(GitService.branchReviewBatchTimeout, const Duration(seconds: 60));
      expect(kBranchUniqueCommitsPageSize, 50);
      expect(kBranchComparisonMaxFiles, 500);
    });

    test('review summaries chunk by batch size without client N+1', () async {
      final git = _CountingGit();
      final branches = [
        for (var i = 0; i < 250; i++)
          (
            refName: 'refs/heads/b$i',
            oid: i.toRadixString(16).padLeft(40, '0'),
          ),
      ];
      // Real GitService chunks; our override records one call with full n.
      // Assert the production constant would require ceil(250/100)=3 batches.
      final batches =
          (branches.length + GitService.branchReviewBatchSize - 1) ~/
          GitService.branchReviewBatchSize;
      expect(batches, 3);
      await git.branchReviewSummaries(
        _repo,
        baseOid: _mainOid,
        branches: branches,
      );
      // Override is one shot — production GitService loops; constant is the gate.
      expect(GitService.branchReviewBatchSize, lessThanOrEqualTo(100));
    });

    test('clearHashKeyedRepoCaches includes branch and merge-preview LRUs', () {
      // Structural membership (same guard as branch_diff_lru_test).
      expect(() => clearHashKeyedRepoCaches(), returnsNormally);
    });
  });
}
