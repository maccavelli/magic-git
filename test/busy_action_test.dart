// The shared BusyActionState contract — extracted from five drifted copies
// (Repository, History, Branches, Stashes, Worktrees). The load-bearing
// pieces: refresh runs even when the op FAILS (a thrown GitException is how
// GitService signals a conflict), a re-entrant call while busy is a no-op,
// and NOTHING (refresh, setState) runs after the view is disposed — the
// worktrees copy called its refresh outside the mounted guard, a
// post-dispose `ref` touch this file pins the fix for.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/busy_action.dart';

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with BusyActionState {
  int refreshes = 0;

  @override
  void refreshAfterAction() => refreshes++;

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  Future<_HostState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MacosApp(debugShowCheckedModeBanner: false, home: _Host()),
      ),
    );
    return tester.state<_HostState>(find.byType(_Host));
  }

  testWidgets('refreshes even when the op fails', (tester) async {
    final host = await pumpHost(tester);

    final done = host.runGuarded(() async => throw Exception('conflict'));
    await tester.pumpAndSettle(); // let the error dialog appear
    expect(find.textContaining('conflict'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(await done, isFalse);
    expect(
      host.refreshes,
      1,
      reason: 'a thrown GitException is how a conflict is signaled — the '
          'in-progress state must land on screen now, not on some later '
          'unrelated refresh',
    );
  });

  testWidgets('a re-entrant call while busy is a no-op', (tester) async {
    final host = await pumpHost(tester);
    final gate = Completer<void>();

    final first = host.runGuarded(() => gate.future);
    await tester.pump();
    expect(host.busy, isTrue);

    var secondRan = false;
    final second = await host.runGuarded(() async => secondRan = true);
    expect(second, isFalse);
    expect(secondRan, isFalse);

    gate.complete();
    expect(await first, isTrue);
    await tester.pump();
    expect(host.busy, isFalse);
    expect(host.refreshes, 1, reason: 'only the op that ran refreshes');
  });

  testWidgets('disposal mid-op: no refresh, no setState, no throw', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    final gate = Completer<void>();

    final done = host.runGuarded(() => gate.future);
    await tester.pump();

    // Tear the view down while the op is still in flight (a repo switch).
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await done;

    expect(tester.takeException(), isNull);
    expect(
      host.refreshes,
      0,
      reason: 'refreshAfterAction touches ref, which throws after disposal — '
          'the worktrees copy of this runner had exactly that bug',
    );
  });

  testWidgets('holdBusyWhile holds the gate without refreshing', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    final gate = Completer<void>();

    final held = host.holdBusyWhile(() => gate.future);
    await tester.pump();
    expect(host.busy, isTrue);

    gate.complete();
    await held;
    await tester.pump();
    expect(host.busy, isFalse);
    expect(host.refreshes, 0, reason: 'modal flows own their own refreshing');
  });
}
