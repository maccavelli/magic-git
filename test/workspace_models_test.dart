import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/features/common/repository_workspace_models.dart';

void main() {
  group('WorkspaceSizeClass', () {
    test('classifies the exact compact, standard, and wide boundaries', () {
      expect(WorkspaceSizeClass.fromWidth(0), WorkspaceSizeClass.compact);
      expect(WorkspaceSizeClass.fromWidth(719.999), WorkspaceSizeClass.compact);
      expect(WorkspaceSizeClass.fromWidth(720), WorkspaceSizeClass.standard);
      expect(
        WorkspaceSizeClass.fromWidth(1199.999),
        WorkspaceSizeClass.standard,
      );
      expect(WorkspaceSizeClass.fromWidth(1200), WorkspaceSizeClass.wide);
      expect(WorkspaceSizeClass.fromWidth(4000), WorkspaceSizeClass.wide);
    });
  });

  group('workspace design tokens', () {
    test('density tightens hit targets without dropping below the floor', () {
      final compact = AppTheme.workspaceTokens(WorkspaceDensity.compact);
      final comfortable = AppTheme.workspaceTokens(
        WorkspaceDensity.comfortable,
      );
      // The row-rhythm tokens this used to assert on were read by nothing —
      // rows size from their content — so they are gone. What remains is the
      // one metric with real consumers, and its accessibility floor.
      expect(
        compact.metrics.minimumTargetSize,
        lessThan(comfortable.metrics.minimumTargetSize),
      );
      expect(compact.metrics.minimumTargetSize, greaterThanOrEqualTo(28));
    });

    test('high contrast strengthens focus and selection treatments', () {
      final normal = AppTheme.workspaceTokens(WorkspaceDensity.comfortable);
      final contrast = AppTheme.workspaceTokens(
        WorkspaceDensity.comfortable,
        highContrast: true,
      );
      expect(contrast.palette.focus, isNot(normal.palette.focus));
      expect(contrast.palette.selection, isNot(normal.palette.selection));
      expect(contrast.palette.border, isNot(normal.palette.border));
    });
  });

  group('WorkspaceSelection', () {
    test('uses stable identities and preserves a valid anchor', () {
      final selection = WorkspaceSelection(
        kind: WorkspaceSelectionKind.changedPath,
        ids: {'unstaged:lib/a.dart', 'unstaged:lib/b.dart'},
        anchorId: 'unstaged:lib/a.dart',
      );
      expect(selection.count, 2);
      expect(selection.isEmpty, isFalse);
      expect(selection.contains('unstaged:lib/b.dart'), isTrue);
    });

    test('rejects an anchor outside the selected identities', () {
      expect(
        () => WorkspaceSelection(
          kind: WorkspaceSelectionKind.commit,
          ids: const {'abc'},
          anchorId: 'def',
        ),
        throwsAssertionError,
      );
    });
  });

  group('WorkspaceAction', () {
    test('runs an enabled action and exposes its deterministic contract', () {
      var calls = 0;
      final action = WorkspaceAction(
        id: 'repository.stage',
        label: 'Stage',
        intent: WorkspaceActionIntent.primary,
        shortcutHint: 'Space',
        onInvoke: () => calls++,
      );

      expect(action.enabled, isTrue);
      expect(action.disabledReason, isNull);
      expect(action.destructive, isFalse);
      action.invoke();
      expect(calls, 1);
    });

    test('a disabled action explains why and never invokes', () {
      const action = WorkspaceAction.disabled(
        id: 'repository.commit',
        label: 'Commit',
        intent: WorkspaceActionIntent.primary,
        reason: 'Stage at least one change.',
      );

      expect(action.enabled, isFalse);
      expect(action.disabledReason, 'Stage at least one change.');
      expect(action.invoke, returnsNormally);
    });
  });

  test('WorkspaceAsyncState distinguishes stale data from first load', () {
    const loading = WorkspaceAsyncState<List<int>>.loading();
    const stale = WorkspaceAsyncState<List<int>>.stale([1, 2]);
    const partial = WorkspaceAsyncState<List<int>>.partialError([
      1,
      2,
    ], 'refresh failed');

    expect(loading.hasData, isFalse);
    expect(stale.hasData, isTrue);
    expect(stale.isStale, isTrue);
    expect(partial.hasError, isTrue);
    expect(partial.hasData, isTrue);
  });
}
