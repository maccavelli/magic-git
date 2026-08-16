// Which surface a commit is composed on (0012), and the preference that picks
// it.
//
// The case that matters most is the preset sweep: the docked composer was
// unreachable by its own shortcut under Review, Investigate and Minimal,
// because all three collapse the task dock (0008-PLAN B9). A sheet is drawn
// over the workspace, so no layout preference can hide it.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';

void main() {
  group('the preference', () {
    test('defaults to the focused sheet', () {
      expect(
        const RepositoryWorkspacePrefs().commitSurface,
        CommitSurface.sheet,
      );
      expect(defaultCommitSurface, CommitSurface.sheet);
    });

    test('round-trips a chosen surface', () {
      const docked = RepositoryWorkspacePrefs(
        commitSurface: CommitSurface.dock,
      );
      expect(
        RepositoryWorkspacePrefs.decode(docked.encode()).commitSurface,
        CommitSurface.dock,
      );
    });

    test('a record written before the field existed takes the default', () {
      // Unlike the toolbar slots (0011), no older build ever wrote a different
      // meaning for this key — absent simply means "never chosen".
      final withoutKey = RepositoryWorkspacePrefs.decode(
        const RepositoryWorkspacePrefs().encode().replaceFirst(
          RegExp(r',"commitSurface":"[a-z]+"'),
          '',
        ),
      );
      expect(withoutKey.commitSurface, defaultCommitSurface);
    });

    test('an unknown surface name falls back rather than throwing', () {
      final garbled = const RepositoryWorkspacePrefs().encode().replaceFirst(
        RegExp(r'"commitSurface":"[a-z]+"'),
        '"commitSurface":"hologram"',
      );
      expect(
        RepositoryWorkspacePrefs.decode(garbled).commitSurface,
        defaultCommitSurface,
      );
    });

    test('choosing a surface leaves every other field alone', () {
      const original = RepositoryWorkspacePrefs(
        preset: WorkspacePreset.minimal,
        navigatorWidth: 400,
        diffLayout: RepositoryDiffLayout.split,
        grouping: RepositoryChangeGrouping.directory,
        visibleToolbarSlots: {WorkspaceToolbarSlot.refresh},
      );
      final next = original.copyWith(commitSurface: CommitSurface.dock);
      expect(next.commitSurface, CommitSurface.dock);
      expect(next.preset, WorkspacePreset.minimal);
      expect(next.navigatorWidth, 400);
      expect(next.diffLayout, RepositoryDiffLayout.split);
      expect(next.grouping, RepositoryChangeGrouping.directory);
      expect(next.visibleToolbarSlots, {WorkspaceToolbarSlot.refresh});
    });
  });

  group('presets do not touch the commit surface', () {
    // A preset rearranges panes. It must not silently move where committing
    // happens — that is the whole failure mode 0008-PLAN B9 described, where
    // three of four presets took the composer away.
    for (final preset in WorkspacePreset.values) {
      test('${preset.label} preserves it', () {
        for (final surface in CommitSurface.values) {
          final applied = applyWorkspacePreset(
            RepositoryWorkspacePrefs(commitSurface: surface),
            preset,
          );
          expect(
            applied.commitSurface,
            surface,
            reason: '${preset.label} changed the commit surface',
          );
        }
      });
    }

    test('the sheet survives every preset that collapses the task dock', () {
      final collapsing = [
        for (final preset in WorkspacePreset.values)
          if (applyWorkspacePreset(
            const RepositoryWorkspacePrefs(),
            preset,
          ).taskDockCollapsed)
            preset,
      ];
      expect(
        collapsing.length,
        greaterThanOrEqualTo(3),
        reason: 'Review, Investigate and Minimal all collapse the dock',
      );
      for (final preset in collapsing) {
        final applied = applyWorkspacePreset(
          const RepositoryWorkspacePrefs(),
          preset,
        );
        expect(applied.commitSurface, CommitSurface.sheet);
      }
    });
  });
}
