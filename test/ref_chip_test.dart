import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/history/ref_chip.dart';

const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('refDecorationTooltip', () {
    test('local non-HEAD branch', () {
      const ref = GitRef(
        name: 'refs/heads/feature',
        oid: _hash,
        isHead: false,
        subject: 's',
      );
      expect(refDecorationTooltip(ref), 'Local branch feature');
    });

    test('branch checked out in another worktree', () {
      const ref = GitRef(
        name: 'refs/heads/experiment',
        oid: _hash,
        isHead: false,
        subject: 's',
        worktreePath: '/home/x/wt',
      );
      expect(
        refDecorationTooltip(ref),
        'Branch experiment\nChecked out in the worktree at /home/x/wt',
      );
    });

    test('fallback for an unmapped ref', () {
      // A ref that is none of the recognised kinds — falls through to
      // returning the short name as-is.
      const ref = GitRef(
        name: 'refs/stash',
        oid: _hash,
        isHead: false,
        subject: 's',
      );
      expect(refDecorationTooltip(ref), 'refs/stash');
    });
  });

  group('refDecorationLabel', () {
    test('returns shortName for a tag', () {
      const ref = GitRef(
        name: 'refs/tags/v1',
        oid: _hash,
        isHead: false,
        subject: 's',
      );
      expect(refDecorationLabel(ref), 'v1');
    });

    test('returns shortName for a non-HEAD branch', () {
      const ref = GitRef(
        name: 'refs/heads/dev',
        oid: _hash,
        isHead: false,
        subject: 's',
      );
      expect(refDecorationLabel(ref), 'dev');
    });
  });

  group('RefChipStrip.effectiveMaxVisible', () {
    test('defaults to maxVisible', () {
      // The default strip uses the class constant.
      expect(RefChipStrip.maxVisible, 2);
    });
  });
}
