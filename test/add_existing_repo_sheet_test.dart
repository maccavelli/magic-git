// The Add Existing Repository sheet's scoped-toggle ↔ fsmonitor interlock:
// git's fsmonitor daemon is never valid on a scoped work-tree repo (it would
// index the entire work tree — all of $HOME for a dotfiles repo — and git
// refuses it on a bare git-dir anyway), so flipping the scoped toggle on must
// force the fsmonitor toggle off AND disable it until scoped is off again.
//
// (The folder-pick auto-detection that can also flip the scoped toggle is
// exercised against real git in scoped_repo_autodetect_test.dart — the native
// picker doesn't run under `flutter test`.)

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/connection/local_repo_form.dart';

/// The MacosSwitch sitting in the same Row as the label [text] — the switches
/// carry no semantics of their own, so the row label is the stable handle.
Finder _switchNear(String text) => find.descendant(
  of: find.ancestor(of: find.textContaining(text), matching: find.byType(Row)),
  matching: find.byType(MacosSwitch),
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedConnectionsProvider.overrideWith((ref) async => const []),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: AddExistingRepoSheet(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('turning the scoped toggle on forces fsmonitor off and disables '
      'it; turning it off re-enables', (tester) async {
    await _pump(tester);

    final fsmonitor = _switchNear('Enable filesystem monitor');
    final scoped = _switchNear('Scoped work-tree repo');

    // Enable fsmonitor first so the interlock has something to clear.
    await tester.ensureVisible(fsmonitor);
    await tester.tap(fsmonitor);
    await tester.pumpAndSettle();
    expect(tester.widget<MacosSwitch>(fsmonitor).value, isTrue);

    await tester.ensureVisible(scoped);
    await tester.tap(scoped);
    await tester.pumpAndSettle();

    final locked = tester.widget<MacosSwitch>(fsmonitor);
    expect(locked.value, isFalse, reason: 'scoped must clear fsmonitor');
    expect(
      locked.onChanged,
      isNull,
      reason: 'fsmonitor must be disabled while scoped',
    );
    expect(find.textContaining('Not available for a scoped'), findsOneWidget);

    // Off again: editable once more, but stays off — no silent re-enable.
    await tester.tap(scoped);
    await tester.pumpAndSettle();
    final unlocked = tester.widget<MacosSwitch>(fsmonitor);
    expect(unlocked.value, isFalse);
    expect(unlocked.onChanged, isNotNull);
  });
}
