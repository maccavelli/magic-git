import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';
const _main = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _feature = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _stale = 'cccccccccccccccccccccccccccccccccccccccc';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: _main, isHead: true, subject: 'main'),
  GitRef(
    name: 'refs/heads/feature',
    oid: _feature,
    isHead: false,
    subject: 'feature',
  ),
  GitRef(
    name: 'refs/remotes/origin/feature',
    oid: _feature,
    isHead: false,
    subject: 'feature',
  ),
  GitRef(
    name: 'refs/heads/stale',
    oid: _stale,
    isHead: false,
    subject: 'stale',
    creatorDate: 1,
  ),
  GitRef(name: 'refs/tags/v1', oid: _main, isHead: false, subject: 'release'),
];

class _NoopGit extends GitService {
  _NoopGit() : super(SSHCommandExecutor(SSHClientManager()));
}

void main() {
  testWidgets('Browse is lazy; Review names base and shows local summaries', (
    tester,
  ) async {
    var baseReads = 0;
    var reviewReads = 0;
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_NoopGit()),
        refsProvider(_repo).overrideWith((ref) async => _refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        // Review reads the typed knowledge provider (badge painting reads the
        // plain map above). Left unstubbed it would reach forgeProvider and,
        // through it, a real executor.
        branchForgeKnowledgeProvider(
          _repo,
        ).overrideWith((ref) async => BranchForgeKnowledge.unavailable),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
        branchBaseProvider.overrideWith((ref, key) async {
          baseReads++;
          return const BranchBaseResolution(
            base: BranchBase(
              refName: 'refs/heads/main',
              displayName: 'main',
              oid: _main,
              source: BranchBaseSource.localMain,
              isFallback: false,
            ),
          );
        }),
        branchReviewProvider.overrideWith((ref, key) async {
          reviewReads++;
          return const BranchReviewBatchResult(
            summariesByRefName: {
              'refs/heads/main': BranchReviewSummary(
                refName: 'refs/heads/main',
                shortName: 'main',
                branchOid: _main,
                baseOid: _main,
                aheadOfBase: 0,
                behindBase: 0,
              ),
              'refs/heads/feature': BranchReviewSummary(
                refName: 'refs/heads/feature',
                shortName: 'feature',
                branchOid: _feature,
                baseOid: _main,
                aheadOfBase: 2,
                behindBase: 1,
              ),
              'refs/heads/stale': BranchReviewSummary(
                refName: 'refs/heads/stale',
                shortName: 'stale',
                branchOid: _stale,
                baseOid: _main,
                aheadOfBase: 1,
                behindBase: 0,
              ),
            },
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(home: BranchesView(repoPath: _repo)),
      ),
    );
    await tester.pumpAndSettle();

    // Browse with no selection does not resolve base or review summary.
    expect(baseReads, 0);
    expect(reviewReads, 0);
    expect(find.text('origin/feature'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(baseReads, 1);
    expect(reviewReads, 1);
    expect(find.text('Compared with'), findsOneWidget);
    expect(find.text('Local main fallback'), findsOneWidget);
    expect(find.text('origin/feature'), findsNothing);
    expect(find.text('v1'), findsNothing);
    expect(find.text('↑2 ↓1'), findsOneWidget);
    // Review now opens on the design's attention order rather than Activity;
    // Activity remains available in the expanded sort menu.
    expect(find.text('Smart'), findsOneWidget);
    // The composable facets that have no dashboard chip live behind this.
    expect(find.text('Filter'), findsOneWidget);

    await tester.tap(find.text('Merged'));
    await tester.pumpAndSettle();
    expect(find.text('↑2 ↓1'), findsNothing);
    expect(find.text('stale'), findsNothing);

    await tester.tap(find.text('Merged'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stale'));
    await tester.pumpAndSettle();
    expect(find.text('stale'), findsOneWidget);
    expect(find.text('↑2 ↓1'), findsNothing);
    expect(find.textContaining('safe to clean up'), findsNothing);
    expect(find.textContaining('safe to delete'), findsNothing);
  });

  testWidgets('Review shows an explicit no-base state for an unborn repo', (
    tester,
  ) async {
    var reviewReads = 0;
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_NoopGit()),
        refsProvider(_repo).overrideWith((ref) async => const []),
        remotesProvider(_repo).overrideWith((ref) async => const []),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        // Review reads the typed knowledge provider (badge painting reads the
        // plain map above). Left unstubbed it would reach forgeProvider and,
        // through it, a real executor.
        branchForgeKnowledgeProvider(
          _repo,
        ).overrideWith((ref) async => BranchForgeKnowledge.unavailable),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
        branchBaseProvider.overrideWith(
          (ref, key) async => const BranchBaseResolution(),
        ),
        branchReviewProvider.overrideWith((ref, key) async {
          reviewReads++;
          return const BranchReviewBatchResult();
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(home: BranchesView(repoPath: _repo)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(
      find.text('This repository has no commit to compare yet.'),
      findsNWidgets(2),
    );
    expect(reviewReads, 0);
  });
}
