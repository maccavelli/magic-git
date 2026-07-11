// The undo toast layer: journal growth for the active repo shows a
// click-to-undo toast with the live ⌘Z hint, direct announcements ("Undid: …")
// show without one, and the auto-dismiss window closes it.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/core/undo/undo_journal.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';
import 'package:remote_magic_git/features/common/undo_toast.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

UndoRecord _record(String description) => UndoRecord(
  repoPath: '/repo',
  kind: UndoOpKind.commit,
  description: description,
  preHead: 'a' * 40,
  preRef: 'main',
  postHead: 'b' * 40,
  postRef: 'main',
);

void main() {
  late ProviderContainer container;
  late int undoCalls;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    undoCalls = 0;
    container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _StubConnection(
            const ConnectionState(
              phase: ConnectionPhase.connected,
              repoPath: '/repo',
              host: 'h',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Stack(
            children: [
              UndoToastOverlay(
                onUndo: () async {
                  undoCalls++;
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('a journal push for the active repo shows a hinted toast', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Commit'), findsNothing);

    container.read(undoJournalProvider.notifier).push(_record('Commit'));
    await tester.pumpAndSettle();

    expect(find.text('Commit'), findsOneWidget);
    expect(find.text('⌘Z'), findsOneWidget, reason: 'default binding hint');
    expect(find.text('to undo'), findsOneWidget);

    // Run out the auto-dismiss timer so no timer outlives the test.
    await tester.pump(UndoToastNotifier.visibleFor);
    await tester.pumpAndSettle();
  });

  testWidgets('a push for a different repo shows nothing', (tester) async {
    await pump(tester);
    final other = UndoRecord(
      repoPath: '/elsewhere',
      kind: UndoOpKind.commit,
      description: 'Commit',
      preHead: 'a' * 40,
      preRef: 'main',
      postHead: 'b' * 40,
      postRef: 'main',
    );
    container.read(undoJournalProvider.notifier).push(other);
    await tester.pumpAndSettle();
    expect(find.text('Commit'), findsNothing);
  });

  testWidgets('popping the journal does not toast', (tester) async {
    await pump(tester);
    final journal = container.read(undoJournalProvider.notifier);
    journal.push(_record('Commit'));
    await tester.pumpAndSettle();
    container.read(undoToastProvider.notifier).dismiss();
    await tester.pumpAndSettle();
    // The text lingers in the tree for the fade-out — invisibility is the
    // provider being null plus a fully faded overlay.
    expect(container.read(undoToastProvider), isNull);
    final faded = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(faded.opacity, 0);

    journal.pop('/repo');
    await tester.pumpAndSettle();
    expect(container.read(undoToastProvider), isNull,
        reason: 'an executed/discarded undo is not a new operation');
  });

  testWidgets('clicking a hinted toast runs the undo and dismisses', (
    tester,
  ) async {
    await pump(tester);
    container.read(undoJournalProvider.notifier).push(_record('Commit'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();

    expect(undoCalls, 1);
    expect(container.read(undoToastProvider), isNull);
  });

  testWidgets('the toast auto-dismisses after its visibility window', (
    tester,
  ) async {
    await pump(tester);
    container.read(undoJournalProvider.notifier).push(_record('Commit'));
    await tester.pumpAndSettle();
    expect(container.read(undoToastProvider), isNotNull);

    await tester.pump(
      UndoToastNotifier.visibleFor + const Duration(milliseconds: 1),
    );
    expect(container.read(undoToastProvider), isNull);
    await tester.pumpAndSettle(); // let the fade-out finish
  });

  testWidgets('a direct announcement shows without the undo hint', (
    tester,
  ) async {
    await pump(tester);
    container
        .read(undoToastProvider.notifier)
        .show(const UndoToast('Undid: Commit'));
    await tester.pumpAndSettle();

    expect(find.text('Undid: Commit'), findsOneWidget);
    expect(find.text('to undo'), findsNothing);

    // Clicking a plain announcement only dismisses.
    await tester.tap(find.text('Undid: Commit'));
    await tester.pumpAndSettle();
    expect(undoCalls, 0);
    expect(container.read(undoToastProvider), isNull);
  });

  testWidgets('the hint renders the live (remapped) binding', (tester) async {
    await pump(tester);
    await container.read(keymapProvider.notifier).setBindings('global.undo', [
      KeyBinding.fromKey(LogicalKeyboardKey.keyU, meta: true, shift: true),
    ]);
    container.read(undoJournalProvider.notifier).push(_record('Commit'));
    await tester.pumpAndSettle();

    expect(find.text('⌘Z'), findsNothing);
    expect(find.text('⇧⌘U'), findsOneWidget);

    // Run out the auto-dismiss timer so no timer outlives the test.
    await tester.pump(UndoToastNotifier.visibleFor);
    await tester.pumpAndSettle();
  });
}
