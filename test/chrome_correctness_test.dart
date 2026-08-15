// Phase 0 of MADR 0008: the correctness defects the chrome inventory surfaced.
//
// These are independent of the chrome redesign — each is a bug on its own
// terms, and each of these assertions fails against the tree before its fix.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/exec/operation_activity.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/activity_center.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';

RepositoryContextSnapshot _snapshot() => const RepositoryContextSnapshot(
  repositoryPath: '/srv/repo',
  repositoryName: 'repo',
  branchLabel: 'main',
  connected: true,
  changedCount: 3,
  conflictCount: 1,
  ahead: 2,
  behind: 1,
);

Future<void> _pumpBar(
  WidgetTester tester, {
  required double width,
  ValueChanged<OperationId>? onRevealOutput,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 200,
            child: RepositoryContextBar(
              snapshot: _snapshot(),
              primaryAction: const RepositoryPrimaryAction(
                kind: RepositoryPrimaryActionKind.fetch,
                label: 'Fetch',
              ),
              onPrimaryAction: (_) {},
              onRevealOutput: onRevealOutput,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('B10 — default prefs match the default preset', () {
    test('a fresh record is exactly what applyWorkspacePreset(review) makes', () {
      const fresh = RepositoryWorkspacePrefs();
      final applied = applyWorkspacePreset(fresh, WorkspacePreset.review);

      // These disagreed: `preset` defaulted to review while `taskDockCollapsed`
      // defaulted to commit's value, so a fresh workspace matched no preset.
      expect(fresh.preset, WorkspacePreset.review);
      expect(fresh.taskDockCollapsed, applied.taskDockCollapsed);
      expect(fresh.navigatorCollapsed, applied.navigatorCollapsed);
      expect(fresh.inspectorCollapsed, applied.inspectorCollapsed);
      expect(fresh.inspectorPinned, applied.inspectorPinned);
    });
  });

  group('B11 — diff preferences are live, not write-only', () {
    test('all three round-trip', () {
      const prefs = RepositoryWorkspacePrefs(
        diffLayout: RepositoryDiffLayout.split,
        ignoreWhitespace: true,
        diffContextLines: 25,
      );
      final restored = RepositoryWorkspacePrefs.decode(prefs.encode());

      expect(restored.diffLayout, RepositoryDiffLayout.split);
      expect(restored.ignoreWhitespace, isTrue);
      expect(restored.diffContextLines, 25);
    });
  });

  group('B8 — the compact metadata disclosure is honest', () {
    testWidgets('it is not a menu of do-nothing items', (tester) async {
      // Below the 720 compact threshold, where _CompactMetadata renders.
      await _pumpBar(tester, width: 600);

      // Every item used to be `onTap: () {}` — it looked actionable, hovered
      // like a menu, and did nothing.
      final inert = tester
          .widgetList<MacosPulldownMenuItem>(find.byType(MacosPulldownMenuItem))
          .where((i) => i.onTap != null);
      expect(inert, isEmpty);
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.ellipsis_circle,
        ),
        findsOneWidget,
      );
    });

    testWidgets('the detail still reaches assistive tech', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpBar(tester, width: 600);

      expect(
        find.bySemanticsLabel(RegExp('Repository details')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('B4 — one Activity button per page', () {
    testWidgets('the bar renders exactly one', (tester) async {
      await _pumpBar(tester, width: 1000);
      expect(find.byType(ActivityCenterButton), findsOneWidget);
    });

    testWidgets('and it forwards onRevealOutput, so it fully replaces the '
        'copy the Repository toolbar used to render', (tester) async {
      await _pumpBar(tester, width: 1000, onRevealOutput: (_) {});

      final button = tester.widget<ActivityCenterButton>(
        find.byType(ActivityCenterButton),
      );
      expect(
        button.onRevealOutput,
        isNotNull,
        reason: 'reveal-in-Output lived only on the deleted duplicate',
      );
    });

    testWidgets('with no callback supplied it stays null rather than faking '
        'the affordance', (tester) async {
      await _pumpBar(tester, width: 1000);

      final button = tester.widget<ActivityCenterButton>(
        find.byType(ActivityCenterButton),
      );
      expect(button.onRevealOutput, isNull);
    });
  });
}
