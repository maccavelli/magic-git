// The pane focus ring is a KEYBOARD affordance.
//
// `WorkspaceFocusRegion` draws a 2 px ring around a whole workspace pane so the
// pane-focus shortcuts (`app_shell.dart`: focus navigator / canvas / inspector
// / task dock) have visible feedback — otherwise they move focus invisibly.
//
// It used to ring on a mouse click too, because `Focus.onFocusChange` fires
// when the node **or any descendant** takes focus: clicking a file in the
// canvas list requests that list's node, and the ancestor region could not tell
// that apart from the shortcut. The result was a window-sized blue outline on
// every file click that only cleared by clicking out of the tab entirely.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/repository_workspace_models.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';
import 'package:remote_magic_git/features/common/workspace_focus_order.dart';

/// True when any pane is currently drawing its focus ring.
///
/// Keyed on the border EXISTING rather than on its colour: the region resolves
/// its colour from the appearance scope when it can see one and falls back to
/// `MacosTheme.primaryColor` otherwise, so asserting a specific colour tests
/// where the widget sits in the tree, not whether the ring is up.
bool _ringVisible(WidgetTester tester) => tester
    .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
    .any((c) {
      final d = c.foregroundDecoration;
      return d is BoxDecoration && d.border != null;
    });

/// A focus change lands in a microtask, and the `setState` it triggers renders
/// on the frame after that — one `pump` is not enough, and a test that used one
/// reported "no ring" for a ring that was about to appear.
Future<void> _settleFocus(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  late FocusNode inner;

  setUp(() => inner = FocusNode(debugLabel: 'inner'));
  tearDown(() => inner.dispose());

  /// The real scaffold — the same one that wraps panes in production — with a
  /// focusable child in the canvas standing in for the file list.
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SizedBox(
              width: 1000,
              height: 600,
              child: RepositoryWorkspaceScaffold(
                repositoryContext: const SizedBox.shrink(),
                canvas: Builder(
                  builder: (context) {
                    return Focus(
                      focusNode: inner,
                      child: const SizedBox.expand(child: Text('canvas')),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the pane-focus shortcut rings the pane', (tester) async {
    await pump(tester);
    expect(_ringVisible(tester), isFalse, reason: 'nothing focused yet');

    expect(
      WorkspacePaneFocusRegistry.instance.request(WorkspacePaneRole.canvas),
      isTrue,
    );
    await _settleFocus(tester);

    expect(
      _ringVisible(tester),
      isTrue,
      reason: 'the shortcut has no other feedback; this is its whole purpose',
    );
  });

  testWidgets('focus taken from INSIDE the pane does not ring it', (
    tester,
  ) async {
    // The reported bug, as a test. Clicking a file focuses a descendant; the
    // pane must stay unringed.
    await pump(tester);
    inner.requestFocus();
    await _settleFocus(tester);

    expect(
      inner.hasFocus,
      isTrue,
      reason: 'the descendant really did take focus',
    );
    expect(
      _ringVisible(tester),
      isFalse,
      reason:
          'a click inside the pane is not the pane-focus shortcut, and a focus '
          'ring on a mouse click is not the platform convention',
    );
  });

  testWidgets('a pointer press dismisses a ring the shortcut put up', (
    tester,
  ) async {
    // Focus does not change when the user clicks inside the pane that already
    // holds it, so `onFocusChange` never fires and the ring would otherwise
    // stay until focus left the tab — the second half of the report.
    await pump(tester);
    WorkspacePaneFocusRegistry.instance.request(WorkspacePaneRole.canvas);
    await _settleFocus(tester);
    expect(_ringVisible(tester), isTrue);

    await tester.tapAt(tester.getCenter(find.text('canvas')));
    await _settleFocus(tester);

    expect(
      _ringVisible(tester),
      isFalse,
      reason: 'clicking should put the ring away, not require leaving the tab',
    );
  });
}
