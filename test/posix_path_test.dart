// Contracts for the canonical POSIX path helpers (MADR 0033 Phase 2).
//
// These pin behaviour that used to differ between eight private copies, so the
// edges are the point of the file: a bare root, repeated slashes, and the
// empty string. Two pairs of functions deliberately disagree with each other
// (see posix_path.dart) and the tests below state which is which, so a future
// "tidy-up" that merges them fails here rather than silently disabling
// `HostFsService.removeDirGuarded`'s root refusal.
//
// Every expectation was checked against the original implementation it
// replaces before being written down.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/posix_path.dart';

void main() {
  group('basename', () {
    test('takes the last non-empty segment', () {
      expect(basename('/a/b'), 'b');
      expect(basename('/repo/'), 'repo');
      expect(basename('repo'), 'repo');
    });

    test('tolerates repeated slashes anywhere', () {
      expect(basename('a/b//'), 'b');
      expect(basename('a//b'), 'b');
    });

    test('never returns empty for a non-empty path', () {
      // The property that made this the canonical family: a display label
      // must not come back blank. The variant this replaced in drag_item.dart
      // returned '' for all three of these.
      expect(basename('/'), '/');
      expect(basename('//'), '//');
      expect(basename('///'), '///');
    });

    test('passes the empty string through', () {
      expect(basename(''), '');
    });
  });

  group('dirname', () {
    test('treats a trailing slash as insignificant', () {
      expect(dirname('a/b//'), 'a');
      expect(dirname('/a/b'), '/a');
    });

    test('gives root when there is no parent above it', () {
      expect(dirname('/repo/'), '/');
      expect(dirname('repo'), '/');
      expect(dirname('/'), '/');
      expect(dirname('//'), '/');
      expect(dirname('///'), '/');
      expect(dirname(''), '/');
    });

    test('inherits _dirOf on an interior double slash', () {
      // 'a/' rather than 'a' — the last slash wins and interior empties are
      // not collapsed. Pinned because it is inherited, not designed: if it is
      // ever changed, that should be a deliberate decision with this test in
      // the diff.
      expect(dirname('a//b'), 'a/');
    });
  });

  group('stripTrailingSlashes (root-collapsing)', () {
    test('collapses a bare root to empty — the rm -rf guard depends on it', () {
      // HostFsService.removeDirGuarded refuses a delete when the normalized
      // parent is empty. Preserve the root here and that guard becomes dead
      // code while its own test still passes.
      expect(stripTrailingSlashes('/'), '');
      expect(stripTrailingSlashes('//'), '');
      expect(stripTrailingSlashes('///'), '');
    });

    test('strips every trailing slash, leaves the interior alone', () {
      expect(stripTrailingSlashes('a/b//'), 'a/b');
      expect(stripTrailingSlashes('/repo/'), '/repo');
      expect(stripTrailingSlashes('/a/b'), '/a/b');
      expect(stripTrailingSlashes('a//b'), 'a//b');
      expect(stripTrailingSlashes('repo'), 'repo');
      expect(stripTrailingSlashes(''), '');
    });
  });

  group('stripTrailingSlashesKeepRoot', () {
    test('keeps a bare root', () {
      expect(stripTrailingSlashesKeepRoot('/'), '/');
      expect(stripTrailingSlashesKeepRoot('//'), '/');
      expect(stripTrailingSlashesKeepRoot('///'), '/');
    });

    test('is otherwise identical to the collapsing variant', () {
      for (final path in ['a/b//', '/repo/', '/a/b', 'a//b', 'repo', '']) {
        expect(
          stripTrailingSlashesKeepRoot(path),
          stripTrailingSlashes(path),
          reason: 'the two variants may only differ at the root',
        );
      }
    });
  });
}
