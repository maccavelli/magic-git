// Plan 0003 Phase 4's discovery layer, wired.
//
// `branch_review_query.dart` shipped complete and unit-tested but entirely
// unreferenced by the UI: Review used a 4-value quick filter, a 2-value sort,
// and a plain substring name match, while the token grammar, the nine facets
// and the five sort modes sat unreachable. These assert the layer is actually
// reached — and that the facets which reason about ABSENCE stay honest.

import 'package:flutter/widgets.dart';
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
const _mainOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _featOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _choreOid = 'cccccccccccccccccccccccccccccccccccccccc';

const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: _mainOid,
    isHead: true,
    subject: 'main',
    authorName: 'Mac',
    authorEmail: 'mac@example.test',
  ),
  // Published (has an upstream), authored by someone else.
  GitRef(
    name: 'refs/heads/feature',
    oid: _featOid,
    isHead: false,
    subject: 'feature',
    upstream: 'origin/feature',
    authorName: 'Robin',
    authorEmail: 'robin@example.test',
  ),
  // Never pushed.
  GitRef(
    name: 'refs/heads/chore',
    oid: _choreOid,
    isHead: false,
    subject: 'chore',
    authorName: 'Mac',
    authorEmail: 'mac@example.test',
  ),
];

class _NoopGit extends GitService {
  _NoopGit() : super(SSHCommandExecutor(SSHClientManager()));
}

Future<ProviderContainer> _pumpReview(
  WidgetTester tester, {
  BranchForgeKnowledge knowledge = BranchForgeKnowledge.unavailable,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_NoopGit()),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      branchForgeKnowledgeProvider(
        _repo,
      ).overrideWith((ref) async => knowledge),
      mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
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
      branchReviewProvider.overrideWith(
        (ref, key) async => const BranchReviewBatchResult(
          summariesByRefName: {
            'refs/heads/feature': BranchReviewSummary(
              refName: 'refs/heads/feature',
              shortName: 'feature',
              branchOid: _featOid,
              baseOid: _mainOid,
              aheadOfBase: 5,
              behindBase: 0,
            ),
            'refs/heads/chore': BranchReviewSummary(
              refName: 'refs/heads/chore',
              shortName: 'chore',
              branchOid: _choreOid,
              baseOid: _mainOid,
              aheadOfBase: 1,
              behindBase: 0,
            ),
          },
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
  await tester.tap(find.text('Review'));
  await tester.pumpAndSettle();
  return container;
}

/// The navigator's search field placeholder also contains "Filter", so target
/// the menu by key rather than by text.
final _facetMenu = find.byKey(const ValueKey('branch-facet-menu'));

Future<void> _openFacets(WidgetTester tester) async {
  await tester.tap(_facetMenu);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the sort menu offers all five modes, not just two', (
    tester,
  ) async {
    await _pumpReview(tester);

    await tester.tap(find.text('Smart'));
    await tester.pumpAndSettle();

    for (final mode in ['Smart', 'Activity', 'Name', 'Ahead', 'Behind']) {
      expect(find.text(mode), findsWidgets, reason: '$mode should be offered');
    }
  });

  testWidgets('an Unpublished facet filters to branches with no upstream', (
    tester,
  ) async {
    await _pumpReview(tester);

    expect(find.text('feature'), findsOneWidget);
    expect(find.text('chore'), findsOneWidget);

    await _openFacets(tester);
    await tester.tap(find.text('Unpublished'));
    await tester.pumpAndSettle();

    // 'feature' tracks origin/feature; 'chore' was never pushed.
    expect(find.text('feature'), findsNothing);
    expect(find.text('chore'), findsOneWidget);
  });

  testWidgets('the active facet count surfaces on the menu button', (
    tester,
  ) async {
    await _pumpReview(tester);
    expect(_facetMenu, findsOneWidget);

    await _openFacets(tester);
    await tester.tap(find.text('Unpublished'));
    await tester.pumpAndSettle();

    expect(find.text('Filter (1)'), findsOneWidget);
  });

  testWidgets('Clear filters restores the full list', (tester) async {
    await _pumpReview(tester);

    await _openFacets(tester);
    await tester.tap(find.text('Unpublished'));
    await tester.pumpAndSettle();
    expect(find.text('feature'), findsNothing);

    await _openFacets(tester);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();

    expect(find.text('feature'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
  });

  group('facets that reason about absence stay honest', () {
    testWidgets('request facets are hidden when forge data is unavailable', (
      tester,
    ) async {
      await _pumpReview(tester);
      await _openFacets(tester);

      // An empty-because-it-failed forge map would match EVERY branch as
      // "No request", so the facet is not offered at all.
      expect(find.text('No request'), findsNothing);
      expect(find.text('Has a request'), findsNothing);
      expect(find.text('Failing CI'), findsNothing);
    });

    testWidgets('they appear once the forge has actually answered', (
      tester,
    ) async {
      await _pumpReview(
        tester,
        knowledge: const BranchForgeKnowledge(known: true),
      );
      await _openFacets(tester);

      expect(find.text('No request'), findsOneWidget);
      expect(find.text('Has a request'), findsOneWidget);
      expect(find.text('Failing CI'), findsOneWidget);
    });

    testWidgets('Mine is hidden when no committer identity is configured', (
      tester,
    ) async {
      // AppSettings defaults both identity fields to empty (the host's own
      // git config is used), which would make "Mine" match nothing at all.
      await _pumpReview(tester);
      await _openFacets(tester);

      expect(find.text('Mine'), findsNothing);
    });
  });

  testWidgets('the search box speaks the token grammar in Review', (
    tester,
  ) async {
    await _pumpReview(tester);

    await tester.enterText(find.byType(MacosTextField), 'author:robin');
    await tester.pumpAndSettle();

    // Substring-matching this against branch NAMES — which is what Review did
    // before the shaper was wired — would have eliminated everything.
    expect(find.text('feature'), findsOneWidget);
    expect(find.text('chore'), findsNothing);
  });

  testWidgets('a status: token filters by state, not by name', (tester) async {
    await _pumpReview(tester);

    await tester.enterText(find.byType(MacosTextField), 'status:unpublished');
    await tester.pumpAndSettle();

    expect(find.text('chore'), findsOneWidget);
    expect(find.text('feature'), findsNothing);
  });

  testWidgets('plain text still matches a branch name', (tester) async {
    await _pumpReview(tester);

    await tester.enterText(find.byType(MacosTextField), 'chor');
    await tester.pumpAndSettle();

    expect(find.text('chore'), findsOneWidget);
    expect(find.text('feature'), findsNothing);
  });
}
