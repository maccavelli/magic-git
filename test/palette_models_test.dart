import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/palette_models.dart';
import 'package:remote_magic_git/features/common/palette_row_semantics.dart';

void main() {
  test('parser recognizes category and every entity prefix', () {
    expect(parsePaletteQuery('git: push').scope, PaletteQueryScope.git);
    expect(parsePaletteQuery('branch: feat').scope, PaletteQueryScope.branch);
    expect(parsePaletteQuery('commit: abc').scope, PaletteQueryScope.commit);
    expect(parsePaletteQuery('file: lib/a').scope, PaletteQueryScope.file);
    expect(parsePaletteQuery('stash: wip').scope, PaletteQueryScope.stash);
    expect(
      parsePaletteQuery('worktree: release').scope,
      PaletteQueryScope.worktree,
    );
    expect(parsePaletteQuery('issue: 42').scope, PaletteQueryScope.issue);
    expect(parsePaletteQuery('request: 7').scope, PaletteQueryScope.request);
    expect(parsePaletteQuery('ci: failed').scope, PaletteQueryScope.ci);
    expect(parsePaletteQuery('origin: fix').scope, PaletteQueryScope.all);
    expect(parsePaletteQuery('origin: fix').text, 'origin: fix');
  });

  test(
    'ranking is exact then prefix, focus, recency, fuzzy and deterministic',
    () {
      const entries = <PaletteEntry>[
        BranchPaletteEntry(
          id: 'b:feature',
          primaryLabel: 'feature',
          refName: 'refs/heads/feature',
        ),
        BranchPaletteEntry(
          id: 'b:featured',
          primaryLabel: 'featured',
          refName: 'refs/heads/featured',
          recency: 2,
        ),
        BranchPaletteEntry(
          id: 'b:fritter',
          primaryLabel: 'fritter',
          refName: 'refs/heads/fritter',
        ),
      ];
      final exact = rankPaletteEntries(
        entries,
        parsePaletteQuery('branch: feature'),
        focusedId: 'b:featured',
      );
      expect(exact.map((entry) => entry.id), ['b:feature', 'b:featured']);

      final fuzzy = rankPaletteEntries(
        entries,
        parsePaletteQuery('branch: fritter'),
      );
      expect(fuzzy.single.id, 'b:fritter');
    },
  );

  test('caps each kind at 50 and the combined list at 100', () {
    final entries = <PaletteEntry>[
      for (var i = 0; i < 80; i++)
        BranchPaletteEntry(
          id: 'branch:$i',
          primaryLabel: 'branch $i',
          refName: 'refs/heads/$i',
        ),
      for (var i = 0; i < 80; i++)
        CommitPaletteEntry(
          id: 'commit:$i',
          primaryLabel: 'commit $i',
          oid: '$i',
        ),
      for (var i = 0; i < 80; i++)
        WorktreePaletteEntry(
          id: 'worktree:$i',
          primaryLabel: 'worktree $i',
          path: '/$i',
        ),
    ];
    final ranked = rankPaletteEntries(entries, const PaletteQuery());
    expect(ranked, hasLength(100));
    expect(
      ranked.where((entry) => entry.kind == PaletteEntryKind.branch).length,
      lessThanOrEqualTo(50),
    );
  });

  group('paletteRowSemanticsLabel', () {
    test('speaks the name, the category and the shortcut as one utterance', () {
      // A row renders these as three unrelated leaf nodes; the chip in
      // particular would otherwise be read as a bare word like "app".
      final label = paletteRowSemanticsLabel(
        label: 'Fetch',
        categoryPrefix: 'git',
        shortcut: '\u2318R',
        position: 2,
        count: 9,
      );
      expect(label, 'Fetch, git, shortcut \u2318R, item 2 of 9');
    });

    test('omits the shortcut clause when a command has no binding', () {
      final label = paletteRowSemanticsLabel(
        label: 'Toggle Dashboard',
        categoryPrefix: 'app',
        position: 1,
        count: 3,
      );
      expect(label, 'Toggle Dashboard, app, item 1 of 3');
    });

    test('treats an empty shortcut as absent, not as an empty clause', () {
      final label = paletteRowSemanticsLabel(
        label: 'Push',
        categoryPrefix: 'git',
        shortcut: '',
      );
      expect(label, 'Push, git');
    });

    test('omits the position clause unless both position and count are known',
        () {
      expect(
        paletteRowSemanticsLabel(
          label: 'Push',
          categoryPrefix: 'git',
          position: 3,
        ),
        'Push, git',
      );
    });
  });
}
