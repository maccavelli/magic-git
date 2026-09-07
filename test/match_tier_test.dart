// The app's shared match tiers (MADR 0032 Phase 1), extracted from the command
// palette so the create sheet's namespace search can rank without namespaces
// becoming palette entries.
//
// The tiers are the contract: 0 exact, 1 prefix, 2 substring, 3 subsequence,
// null no match. Tier 1 is the case the maintainer described — a typed prefix
// reaching both an exact group name and a longer one sharing it.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/match_tier.dart';

void main() {
  group('matchTier', () {
    test('an empty query matches everything at tier 0', () {
      // So an unfiltered list keeps its natural order rather than collapsing.
      expect(matchTier(const ['anything'], ''), 0);
      expect(matchTier(const [], ''), 0);
    });

    test('ranks exact above prefix above substring above subsequence', () {
      expect(matchTier(const ['team'], 'team'), 0);
      expect(matchTier(const ['team-platform'], 'team'), 1);
      expect(matchTier(const ['my-team'], 'team'), 2);
      expect(matchTier(const ['t-e-a-m'], 'team'), 3);
    });

    test('no match is null, not a large number', () {
      // Callers filter on null; a sentinel int would silently rank instead.
      expect(matchTier(const ['platform'], 'zzz'), isNull);
    });

    test('is case-insensitive in both directions', () {
      expect(matchTier(const ['Platform'], 'platform'), 0);
      expect(matchTier(const ['platform'], 'PLATFORM'), 0);
    });

    test('the best tier across the values wins', () {
      // An item is searchable by several strings — a name, a path, an id — and
      // matching any of them well beats matching another poorly.
      expect(matchTier(const ['z-x-y', 'exact'], 'exact'), 0);
      expect(matchTier(const ['nothing', 'prefixed-here'], 'prefixed'), 1);
    });

    test('a prefix reaches both an exact name and a longer one sharing it', () {
      // The namespace case: typing a group's name must offer that group AND
      // the longer sibling that starts with it, both as tier<=1.
      const typed = 'team';
      expect(matchTier(const ['team'], typed), 0);
      expect(matchTier(const ['team-infra'], typed), 1);
      expect(matchTier(const ['unrelated'], typed), isNull);
    });

    test('matches a nested path by any segment', () {
      // Namespaces are `parent/child`; a substring match on the full path is
      // what lets a user narrow by either half.
      expect(matchTier(const ['parent/child'], 'parent'), 1);
      expect(matchTier(const ['parent/child'], 'child'), 2);
      expect(matchTier(const ['parent/child'], 'parent/ch'), 1);
    });
  });

  group('subsequenceMatch', () {
    test('accepts in-order, non-adjacent characters', () {
      expect(subsequenceMatch('abc', 'axbxc'), isTrue);
      expect(subsequenceMatch('abc', 'abc'), isTrue);
    });

    test('rejects out-of-order characters', () {
      expect(subsequenceMatch('cba', 'abc'), isFalse);
    });

    test('an empty query is a subsequence of anything', () {
      expect(subsequenceMatch('', 'abc'), isTrue);
    });

    test('a query longer than the target cannot match', () {
      expect(subsequenceMatch('abcd', 'abc'), isFalse);
    });
  });
}
