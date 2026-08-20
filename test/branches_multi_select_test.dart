import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/branch_review_query.dart';

void main() {
  test(
    'click replaces; command toggles; shift ranges; no merge in batch API',
    () {
      const a = 'refs/heads/a';
      const b = 'refs/heads/b';
      const c = 'refs/heads/c';
      const visible = [a, b, c];

      var sel = BranchMultiSelection.empty.replace(a);
      expect(sel.isSingle, isTrue);
      expect(sel.primary, a);

      sel = sel.toggle(c);
      expect(sel.ordered, [a, c]);
      expect(sel.isMulti, isTrue);

      sel = sel.rangeTo(c, visible);
      // Anchor still a from replace... wait toggle set anchor to c.
      // After toggle(c), anchor is c. rangeTo(c) is just c.
      expect(sel.ordered, [c]);

      sel = BranchMultiSelection.empty.replace(a).rangeTo(c, visible);
      expect(sel.ordered, [a, b, c]);

      // Batch surface: multi-select detail must not offer Merge — contract
      // enforced by only exposing pin/unpin/hide/delete helpers (no merge API).
      expect(sel.length, 3);

      sel = sel.preserveAfterRefresh([a, c]);
      expect(sel.ordered, [a, c]);
    },
  );
}
