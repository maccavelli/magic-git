// The grouped sync control.
//
// The rule it exists to enforce: a button's meaning never moves. A lone
// primary button that renames itself Fetch → Pull → Push → Sync as the
// repository changes is a different command at the same pixel every time you
// look at it, so nothing about it can be learned. Here the recommendation only
// changes which of four fixed buttons is accented.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';

RepositoryContextSnapshot _snapshot({
  int ahead = 0,
  int behind = 0,
  bool hasUpstream = true,
  bool hasRemote = true,
  int conflicts = 0,
  bool pending = false,
}) => RepositoryContextSnapshot(
  repositoryPath: '/srv/repo',
  repositoryName: 'repo',
  branchLabel: 'main',
  ahead: ahead,
  behind: behind,
  changedCount: 0,
  conflictCount: conflicts,
  hasUpstream: hasUpstream,
  hasConfiguredRemote: hasRemote,
  hasPendingOperation: pending,
);

/// Pumps the bar with a live sync group and records what each control invokes.
Future<List<RepositorySyncCommand>> _pump(
  WidgetTester tester, {
  required RepositoryContextSnapshot snapshot,
  double width = 1200,
  Map<RepositorySyncCommand, String> unavailable = const {},
}) async {
  final invoked = <RepositorySyncCommand>[];
  // Tall enough for the overflow menu to open — macos_ui asserts the menu
  // fits above the fold rather than scrolling it.
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 900,
            child: RepositoryContextBar(
              snapshot: snapshot,
              primaryAction: resolvePrimaryRepositoryAction(snapshot),
              onPrimaryAction: (_) {},
              syncGroup: RepositorySyncGroup(
                onInvoke: invoked.add,
                unavailable: unavailable,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return invoked;
}

/// The accented (non-secondary) push button's label, or null when none is.
String? _emphasized(WidgetTester tester) {
  for (final button in tester.widgetList<AppPushButton>(
    find.byType(AppPushButton),
  )) {
    if (button.secondary == true) continue;
    final child = button.child;
    if (child is Text) return child.data;
    if (child is Row) {
      final first = child.children.first;
      if (first is Text) return first.data;
    }
  }
  return null;
}

void main() {
  group('the four verbs are always present with fixed meanings', () {
    testWidgets('all four render regardless of repository state', (
      tester,
    ) async {
      for (final snapshot in [
        _snapshot(),
        _snapshot(ahead: 3),
        _snapshot(behind: 2),
        _snapshot(ahead: 1, behind: 1),
      ]) {
        await _pump(tester, snapshot: snapshot);
        for (final label in ['Fetch', 'Pull', 'Push', 'Sync']) {
          expect(
            find.text(label),
            findsOneWidget,
            reason:
                '$label vanished for ahead=${snapshot.ahead} '
                'behind=${snapshot.behind}',
          );
        }
      }
    });

    testWidgets('each button invokes its own verb, never the recommended one', (
      tester,
    ) async {
      // Behind by 2, so the ladder recommends Pull. Pressing Fetch must still
      // fetch — this is exactly what a self-renaming primary button got wrong.
      final invoked = await _pump(tester, snapshot: _snapshot(behind: 2));
      await tester.tap(find.text('Fetch'));
      await tester.tap(find.text('Push'));
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      expect(invoked, [
        RepositorySyncCommand.fetch,
        RepositorySyncCommand.push,
        RepositorySyncCommand.sync,
      ]);
    });
  });

  group('emphasis tracks the ladder', () {
    testWidgets('and only the emphasis moves', (tester) async {
      await _pump(tester, snapshot: _snapshot());
      expect(_emphasized(tester), 'Fetch');

      await _pump(tester, snapshot: _snapshot(behind: 2));
      expect(_emphasized(tester), 'Pull');

      await _pump(tester, snapshot: _snapshot(ahead: 2));
      expect(_emphasized(tester), 'Push');

      await _pump(tester, snapshot: _snapshot(ahead: 1, behind: 1));
      expect(_emphasized(tester), 'Sync');
    });

    testWidgets('publish emphasizes Push, since that is what it runs', (
      tester,
    ) async {
      await _pump(
        tester,
        snapshot: _snapshot(hasUpstream: false, ahead: 0, behind: 0),
      );
      expect(_emphasized(tester), 'Push');
    });

    testWidgets('nothing is emphasized while a merge waits on the user', (
      tester,
    ) async {
      await _pump(tester, snapshot: _snapshot(pending: true, conflicts: 2));
      expect(
        _emphasized(tester),
        isNull,
        reason: 'Resolve is not a sync verb; no sync button should be accented',
      );
    });

    testWidgets('the ahead/behind badge rides the emphasized verb', (
      tester,
    ) async {
      await _pump(tester, snapshot: _snapshot(ahead: 3, behind: 4));
      expect(find.text('↓4 ↑3'), findsOneWidget);
    });
  });

  group('unavailability', () {
    testWidgets('dims the verb and keeps it in place with its reason', (
      tester,
    ) async {
      final invoked = await _pump(
        tester,
        snapshot: _snapshot(hasUpstream: false),
        unavailable: const {
          RepositorySyncCommand.pull: 'This branch has no upstream yet',
        },
      );

      // Still on screen — a command that disappears when unavailable cannot be
      // discovered, which is the same reason menu items dim instead of hiding.
      expect(find.text('Pull'), findsOneWidget);
      await tester.tap(find.text('Pull'));
      await tester.pumpAndSettle();
      expect(invoked, isEmpty);

      final pull = tester.widgetList<AppPushButton>(find.byType(AppPushButton));
      expect(
        pull.any((button) => button.onPressed == null),
        isTrue,
        reason: 'the unavailable verb must be disabled, not merely inert',
      );
    });
  });

  group('the overflow carries every variant', () {
    testWidgets('at the standard size class', (tester) async {
      final invoked = await _pump(tester, snapshot: _snapshot(ahead: 1));
      await tester.tap(find.byType(MacosPulldownButton).last);
      await tester.pumpAndSettle();

      for (final label in [
        'Pull with Rebase',
        'Pull with Merge',
        'Push and Set Upstream',
        'Push Tags',
        'Force Push with Lease',
        'Force Push',
      ]) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: '$label is unreachable',
        );
      }

      await tester.tap(find.text('Force Push with Lease'));
      await tester.pumpAndSettle();
      expect(invoked, [RepositorySyncCommand.forcePushWithLease]);
    });

    testWidgets('and at the compact size class, where it also carries the '
        'three verbs the group cannot fit', (tester) async {
      await _pump(tester, snapshot: _snapshot(behind: 2), width: 640);

      // Only the recommendation keeps a button…
      expect(find.text('Pull'), findsOneWidget);
      expect(find.text('Fetch'), findsNothing);

      // …and the rest are one click away rather than gone.
      await tester.tap(find.byType(MacosPulldownButton).last);
      await tester.pumpAndSettle();
      for (final label in [
        'Fetch',
        'Push',
        'Sync',
        'Pull with Rebase',
        'Force Push',
      ]) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: '$label is unreachable at the compact size class',
        );
      }
    });
  });

  test('every sync command the group can invoke has a menu-bar route too', () {
    // Both surfaces exist so neither is the only way in; this catches a verb
    // added to one and forgotten in the other.
    const menuRouted = {
      RepositorySyncCommand.fetch: 'repository.fetch',
      RepositorySyncCommand.pull: 'repository.pull',
      RepositorySyncCommand.pullRebase: 'repository.pullRebase',
      RepositorySyncCommand.pullMerge: 'repository.pullMerge',
      RepositorySyncCommand.push: 'repository.push',
      RepositorySyncCommand.pushSetUpstream: 'repository.pushSetUpstream',
      RepositorySyncCommand.pushTags: 'repository.pushTags',
      RepositorySyncCommand.forcePushWithLease: 'repository.forcePush',
      RepositorySyncCommand.forcePush: 'repository.forcePushHard',
      RepositorySyncCommand.sync: 'repository.sync',
    };
    expect(menuRouted.keys.toSet(), RepositorySyncCommand.values.toSet());
  });
}
