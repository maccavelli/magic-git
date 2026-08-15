// What the menu bar knows about availability, and how a menu choice reaches
// the panel that owns it.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/menu_bar_bridge.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  required Map<String, VoidCallback?> handlers,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: PanelShortcuts(
          bindings: const {},
          handlers: handlers,
          child: const SizedBox(),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  group('availability', () {
    testWidgets('a panel publishes only the handlers it can actually run', (
      tester,
    ) async {
      final container = await _pumpPanel(
        tester,
        handlers: {
          'repository.fetch': () {},
          // Null is the established "known but unavailable" convention — the
          // matching menu item must dim rather than run into nothing.
          'repository.discard': null,
          'repository.stash': () {},
        },
      );

      expect(container.read(availableActionsProvider), {
        'repository.fetch',
        'repository.stash',
      });
    });

    testWidgets('an inactive panel (empty map) publishes nothing', (
      tester,
    ) async {
      final container = await _pumpPanel(tester, handlers: const {});
      expect(container.read(availableActionsProvider), isEmpty);
    });

    testWidgets('a background panel cannot blank the live one', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                // The live panel.
                PanelShortcuts(
                  bindings: const {},
                  handlers: {'repository.fetch': () {}},
                  child: const SizedBox(),
                ),
                // Two mounted-but-inactive siblings, exactly as the shell's
                // IndexedStack keeps every visited panel alive.
                const PanelShortcuts(
                  bindings: {},
                  handlers: {},
                  child: SizedBox(),
                ),
                const PanelShortcuts(
                  bindings: {},
                  handlers: {},
                  child: SizedBox(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(container.read(availableActionsProvider), {'repository.fetch'});
    });

    // 0009 H1: cross-panel ids a connected session publishes stay enabled
    // regardless of which panel is active (union with the panel's own set).
    testWidgets('the session set unions with the active panel set', (
      tester,
    ) async {
      final container = await _pumpPanel(
        tester,
        handlers: {'history.copySha': () {}},
      );
      container.read(availableActionsProvider.notifier).publishSession(const {
        'repository.fetch',
        'worktrees.add',
      });

      expect(container.read(availableActionsProvider), {
        'history.copySha',
        'repository.fetch',
        'worktrees.add',
      });

      // Disconnect clears the session set; the panel's set survives.
      container
          .read(availableActionsProvider.notifier)
          .publishSession(const {});
      expect(container.read(availableActionsProvider), {'history.copySha'});
    });

    test('the session set alone enables Fetch with no panel published', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(availableActionsProvider.notifier).publishSession(const {
        'repository.fetch',
      });
      expect(container.read(availableActionsProvider), {'repository.fetch'});
    });

    testWidgets('a disposed panel leaves nothing enabled behind it', (
      tester,
    ) async {
      final container = await _pumpPanel(
        tester,
        handlers: {'repository.fetch': () {}},
      );
      expect(container.read(availableActionsProvider), isNotEmpty);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      await tester.pump();

      expect(container.read(availableActionsProvider), isEmpty);
    });
  });

  group('menu requests', () {
    test('the same command twice is two distinct requests', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(menuActionRequestProvider.notifier);

      notifier.request('repository.fetch');
      final first = container.read(menuActionRequestProvider)!;
      notifier.request('repository.fetch');
      final second = container.read(menuActionRequestProvider)!;

      expect(first.actionId, second.actionId);
      expect(
        second.token,
        greaterThan(first.token),
        reason: 'Fetch chosen twice must run twice',
      );
    });
  });
}
