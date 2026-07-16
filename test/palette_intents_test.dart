// The palette→panel dispatch seam: a panel-scoped action id parked in
// paletteIntentProvider is consumed by the owning panel's PanelShortcuts and
// runs the panel's own handler; unavailable handlers drop the intent instead
// of firing later; foreign ids are left for their owning panel.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/palette_intents.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';

void main() {
  testWidgets('a dispatched intent runs the owning panel handler once and '
      'clears', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var ran = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: PanelShortcuts(
          bindings: const {},
          handlers: {'history.filter': () => ran++},
          child: const SizedBox(),
        ),
      ),
    );

    container.read(paletteIntentProvider.notifier).dispatch('history.filter');
    await tester.pump();

    expect(ran, 1);
    expect(container.read(paletteIntentProvider), isNull, reason: 'consumed');

    // No re-fire on later rebuilds.
    await tester.pump();
    expect(ran, 1);
  });

  testWidgets('an intent parked BEFORE the panel builds is consumed on the '
      'first build — the switch-then-dispatch order the shell uses',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var ran = 0;

    container.read(paletteIntentProvider.notifier).dispatch('stashes.apply');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: PanelShortcuts(
          bindings: const {},
          handlers: {'stashes.apply': () => ran++},
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();

    expect(ran, 1);
    expect(container.read(paletteIntentProvider), isNull);
  });

  testWidgets('an owned-but-unavailable action (null handler) drops the '
      'intent without running anything', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PanelShortcuts(
          bindings: {},
          // Known id, no selection → null handler, resolveShortcuts-style.
          handlers: {'stashes.drop': null},
          child: SizedBox(),
        ),
      ),
    );

    container.read(paletteIntentProvider.notifier).dispatch('stashes.drop');
    await tester.pump();

    expect(
      container.read(paletteIntentProvider),
      isNull,
      reason: 'dropped, so it cannot fire later against a future selection',
    );
  });

  testWidgets('a foreign action id is left for the owning panel', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var ran = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: PanelShortcuts(
          bindings: const {},
          handlers: {'branches.merge': () => ran++},
          child: const SizedBox(),
        ),
      ),
    );

    container.read(paletteIntentProvider.notifier).dispatch('history.amend');
    await tester.pump();

    expect(ran, 0);
    expect(
      container.read(paletteIntentProvider)?.actionId,
      'history.amend',
      reason: 'not ours — stays parked for the owning panel',
    );
  });

  test('an expired intent is dropped at consume time', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(paletteIntentProvider.notifier);

    notifier.dispatch('repository.fetch');
    // Not expired: consuming with the owning map returns the handler.
    void handler() {}
    expect(notifier.consume({'repository.fetch': handler}), same(handler));

    // Re-dispatch, then simulate the TTL passing.
    notifier.dispatch('repository.fetch');
    await Future<void>.delayed(
      PaletteIntentNotifier.maxAge + const Duration(milliseconds: 50),
    );
    expect(notifier.consume({'repository.fetch': handler}), isNull);
    expect(container.read(paletteIntentProvider), isNull);
  });
}
