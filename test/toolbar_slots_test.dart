// Context-bar customization.
//
// Hiding a toolbar item is only safe because every hideable item is also a
// menu-bar command — "a toolbar item can't be the only place that presents a
// command". The identity block and the primary action are not hideable at all:
// a bar you can strip to nothing stops telling you which repository you are
// looking at, or what to do next.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/activity_center.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';

const _snapshot = RepositoryContextSnapshot(
  repositoryPath: '/srv/magic-git',
  repositoryName: 'magic-git',
  branchLabel: 'main',
  changedCount: 0,
  conflictCount: 0,
  hasUpstream: true,
  hasConfiguredRemote: true,
  ahead: 1,
);

Future<void> _pump(
  WidgetTester tester, {
  required Set<WorkspaceToolbarSlot> slots,
}) async {
  tester.view.physicalSize = const Size(1400, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 1400,
            height: 400,
            child: RepositoryWorkspaceScaffold(
              repositoryContext: RepositoryContextBar(
                snapshot: _snapshot,
                primaryAction: resolvePrimaryRepositoryAction(_snapshot),
                onPrimaryAction: (_) {},
                syncGroup: RepositorySyncGroup(onInvoke: (_) {}),
                onStash: () {},
                onRefresh: () {},
                showLinkStatus: true,
              ),
              canvas: const SizedBox.shrink(),
              preferences: RepositoryWorkspacePrefs(visibleToolbarSlots: slots),
              onPreferencesChanged: (_) {},
              workspaceOptionsEnabled: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _tool(String tooltip) => find.byWidgetPredicate(
  (w) => w is ToolIconButton && w.tooltip.startsWith(tooltip),
);

void main() {
  test('every hideable slot is a real, labelled choice', () {
    // A slot with no label would render as "Show " in the menu.
    for (final slot in WorkspaceToolbarSlot.values) {
      expect(slot.label, isNotEmpty);
    }
    expect(
      WorkspaceToolbarSlot.values.length,
      greaterThan(2),
      reason: 'customization used to offer only Back and Forward',
    );
  });

  test('a fresh workspace shows all of them', () {
    const prefs = RepositoryWorkspacePrefs();
    expect(
      prefs.visibleToolbarSlots,
      WorkspaceToolbarSlot.values.toSet(),
      reason: 'hiding is an explicit choice, not a default to discover',
    );
  });

  group('with everything on', () {
    testWidgets('the whole bar renders', (tester) async {
      await _pump(tester, slots: WorkspaceToolbarSlot.values.toSet());

      expect(_tool('Back'), findsOneWidget);
      expect(_tool('Forward'), findsOneWidget);
      expect(_tool('Stash changes'), findsOneWidget);
      expect(_tool('Refresh'), findsOneWidget);
      expect(find.byType(ActivityCenterButton), findsOneWidget);
      expect(find.text('Fetch'), findsOneWidget);
      expect(find.text('Push'), findsOneWidget);
      // The summary is one Text: "Clean  ↑1".
      expect(find.textContaining('Clean'), findsOneWidget);
    });
  });

  group('with everything off', () {
    testWidgets('the hideable items go, one by one', (tester) async {
      await _pump(tester, slots: const {});

      expect(_tool('Back'), findsNothing);
      expect(_tool('Forward'), findsNothing);
      expect(_tool('Stash changes'), findsNothing);
      expect(_tool('Refresh'), findsNothing);
      expect(find.byType(ActivityCenterButton), findsNothing);
      expect(find.textContaining('Clean'), findsNothing);
      expect(find.text('Fetch'), findsNothing);
    });

    testWidgets('but the repository identity stays — it is not customizable', (
      tester,
    ) async {
      await _pump(tester, slots: const {});

      expect(find.text('magic-git'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
    });

    testWidgets('and so does the primary action: hiding the sync group falls '
        'back to the single emphasized button, it does not leave the bar with '
        'no action at all', (tester) async {
      await _pump(tester, slots: const {});

      // Ahead of upstream, so the ladder recommends Push.
      expect(find.text('Push'), findsOneWidget);
    });
  });

  group('one slot at a time', () {
    testWidgets('hiding the sync group keeps Stash and Refresh', (
      tester,
    ) async {
      await _pump(
        tester,
        slots: const {WorkspaceToolbarSlot.stash, WorkspaceToolbarSlot.refresh},
      );

      expect(find.text('Fetch'), findsNothing, reason: 'the group is hidden');
      expect(find.text('Push'), findsOneWidget, reason: 'the primary remains');
      expect(_tool('Stash changes'), findsOneWidget);
      expect(_tool('Refresh'), findsOneWidget);
    });

    testWidgets('hiding Back keeps Forward', (tester) async {
      await _pump(tester, slots: const {WorkspaceToolbarSlot.forward});

      expect(_tool('Back'), findsNothing);
      expect(_tool('Forward'), findsOneWidget);
    });
  });

  test('the choice round-trips to disk', () {
    const prefs = RepositoryWorkspacePrefs(
      visibleToolbarSlots: {
        WorkspaceToolbarSlot.syncGroup,
        WorkspaceToolbarSlot.activity,
      },
    );
    final restored = RepositoryWorkspacePrefs.decode(prefs.encode());

    expect(restored.visibleToolbarSlots, {
      WorkspaceToolbarSlot.syncGroup,
      WorkspaceToolbarSlot.activity,
    });
  });
}
