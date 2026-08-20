import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/branch_review_query.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

GitRef _ref(
  String short, {
  bool isHead = false,
  String? upstream,
  bool upstreamGone = false,
  int ahead = 0,
  int? creatorDate,
  String subject = 's',
  String? authorName,
  String? authorEmail,
  String? worktreePath,
}) => GitRef(
  name: 'refs/heads/$short',
  oid: short.padRight(40, '0').substring(0, 40),
  isHead: isHead,
  subject: subject,
  upstream: upstream,
  upstreamGone: upstreamGone,
  ahead: ahead,
  creatorDate: creatorDate,
  authorName: authorName,
  authorEmail: authorEmail,
  worktreePath: worktreePath,
);

void main() {
  group('parseBranchSearchQuery', () {
    test('plain, author, status, and unknown key:value fallback', () {
      final tokens = parseBranchSearchQuery(
        'feat author:Sam status:stale foo:bar status:nope',
      );
      expect(tokens, hasLength(5));
      expect(tokens[0], isA<PlainSearchToken>());
      expect((tokens[0] as PlainSearchToken).text, 'feat');
      expect(tokens[1], isA<AuthorSearchToken>());
      expect((tokens[1] as AuthorSearchToken).text, 'Sam');
      expect(tokens[2], isA<StatusSearchToken>());
      expect((tokens[2] as StatusSearchToken).status, 'stale');
      // Unknown key:value becomes plain text (not dropped).
      expect(tokens[3], isA<PlainSearchToken>());
      expect((tokens[3] as PlainSearchToken).text, 'foo:bar');
      // Unknown status token also falls back to plain.
      expect(tokens[4], isA<PlainSearchToken>());
      expect((tokens[4] as PlainSearchToken).text, 'status:nope');
    });
  });

  group('compareNaturalBranchName', () {
    test('release/9 before release/10', () {
      expect(compareNaturalBranchName('release/9', 'release/10'), lessThan(0));
      expect(
        compareNaturalBranchName('release/10', 'release/9'),
        greaterThan(0),
      );
      expect(compareNaturalBranchName('a', 'a'), 0);
    });
  });

  group('facets AND + forge known-empty', () {
    test('no-request facet requires known forge data', () {
      final branch = _ref('x');
      final unknown = BranchReviewRowContext(branch: branch, forgeKnown: false);
      final knownEmpty = BranchReviewRowContext(
        branch: branch,
        forgeKnown: true,
      );
      final knownRequest = BranchReviewRowContext(
        branch: branch,
        forgeKnown: true,
        forge: const BranchForge(requestNumber: 1, requestUrl: 'u'),
      );
      const facet = BranchReviewFacets(hasRequest: false);
      expect(matchesBranchReviewFacets(unknown, facet), isFalse);
      expect(matchesBranchReviewFacets(knownEmpty, facet), isTrue);
      expect(matchesBranchReviewFacets(knownRequest, facet), isFalse);
    });

    test('facets compose by AND', () {
      final staleMerged = BranchReviewRowContext(
        branch: _ref(
          'old',
          creatorDate: DateTime.utc(2020).millisecondsSinceEpoch ~/ 1000,
        ),
        summary: const BranchReviewSummary(
          refName: 'refs/heads/old',
          shortName: 'old',
          branchOid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          baseOid: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          aheadOfBase: 0,
          behindBase: 0,
        ),
        forgeKnown: true,
      );
      expect(
        matchesBranchReviewFacets(
          staleMerged,
          const BranchReviewFacets(mergedIntoBase: true, stale: true),
        ),
        isTrue,
      );
      expect(
        matchesBranchReviewFacets(
          staleMerged,
          const BranchReviewFacets(mergedIntoBase: true, stale: false),
        ),
        isFalse,
      );
    });

    test(
      'mine uses email when present else name; disabled without identity',
      () {
        final row = BranchReviewRowContext(
          branch: _ref('x', authorName: 'Sam', authorEmail: 'sam@x.com'),
          committerEmail: 'sam@x.com',
        );
        expect(
          matchesBranchReviewFacets(row, const BranchReviewFacets(mine: true)),
          isTrue,
        );
        expect(
          matchesBranchReviewFacets(
            BranchReviewRowContext(
              branch: _ref('x', authorName: 'Sam', authorEmail: 'other@x.com'),
              committerEmail: 'sam@x.com',
              committerName: 'sam',
            ),
            const BranchReviewFacets(mine: true),
          ),
          isFalse, // email takes precedence when configured
        );
        expect(
          matchesBranchReviewFacets(
            BranchReviewRowContext(
              branch: _ref('x', authorName: 'Sam'),
              committerName: 'sam',
            ),
            const BranchReviewFacets(mine: true),
          ),
          isTrue,
        );
        expect(
          matchesBranchReviewFacets(
            BranchReviewRowContext(branch: _ref('x', authorName: 'Sam')),
            const BranchReviewFacets(mine: true),
          ),
          isFalse,
        );
      },
    );
  });

  group('smart sort is deterministic', () {
    test('conflicts before merged; natural name tiebreak', () {
      final merged = BranchReviewRowContext(
        branch: _ref('z', creatorDate: 100),
        summary: const BranchReviewSummary(
          refName: 'refs/heads/z',
          shortName: 'z',
          branchOid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          baseOid: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          aheadOfBase: 0,
          behindBase: 0,
        ),
      );
      final conflict = BranchReviewRowContext(
        branch: _ref('a', creatorDate: 50),
        conflictKnown: true,
      );
      final rows = [merged, conflict];
      rows.sort(
        (a, b) => compareBranchReviewRows(a, b, BranchReviewSortMode.smart),
      );
      expect(rows.first.branch.shortName, 'a');
      expect(rows.last.branch.shortName, 'z');
    });
  });

  group('BranchMultiSelection', () {
    test('click / toggle / range / refresh drops vanished', () {
      var sel = BranchMultiSelection.empty.replace('refs/heads/a');
      expect(sel.ordered, ['refs/heads/a']);
      sel = sel.toggle('refs/heads/b');
      expect(sel.ordered, ['refs/heads/a', 'refs/heads/b']);
      sel = sel.rangeTo('refs/heads/d', [
        'refs/heads/a',
        'refs/heads/b',
        'refs/heads/c',
        'refs/heads/d',
      ]);
      // Anchor was b from toggle; range b..d.
      expect(sel.ordered, ['refs/heads/b', 'refs/heads/c', 'refs/heads/d']);
      sel = sel.preserveAfterRefresh(['refs/heads/b', 'refs/heads/d']);
      expect(sel.ordered, ['refs/heads/b', 'refs/heads/d']);
    });
  });

  group('gitlabProtectedBranchMatches', () {
    test('literal, star, and path prefix', () {
      expect(gitlabProtectedBranchMatches('main', 'main'), isTrue);
      expect(gitlabProtectedBranchMatches('main', 'master'), isFalse);
      expect(gitlabProtectedBranchMatches('*', 'anything'), isTrue);
      expect(gitlabProtectedBranchMatches('release/*', 'release/1.0'), isTrue);
      expect(gitlabProtectedBranchMatches('release/*', 'feat/1.0'), isFalse);
    });
  });
}
