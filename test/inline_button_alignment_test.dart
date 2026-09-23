// MADR 0068 §C: InlineActionButton wrapped its capsule in a bare `Center` to
// centre it vertically within the minimum target height. `Center` also centres
// horizontally, so the button filled any wide slot and put its capsule in the
// middle — the compact back bar's `Alignment.centerLeft` never applied, and the
// "‹ Commits" capsule sat at x=256 of a 640 pt bar.
//
// Measured on the painted capsule (the AnimatedContainer), not the keyed
// widget: the keyed widget spanning the width is the defect, not the evidence.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/adaptive_workspace_layout.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';

Rect _capsule(WidgetTester tester, Finder button) => tester.getRect(
  find.descendant(of: button, matching: find.byType(AnimatedContainer)).first,
);

void main() {
  testWidgets('the compact back bar keeps its capsule at the left edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 640,
          height: 480,
          child: AdaptiveWorkspaceLayout(
            navigator: const SizedBox(key: Key('navigator')),
            canvas: const SizedBox(key: Key('canvas')),
            navigatorLabel: 'Commits',
            compactNavigation: CompactWorkspaceNavigation(
              navigatorLabel: 'Commits',
              hasSelection: true,
              showCanvas: true,
              onShowNavigator: () {},
            ),
            preferences: const RepositoryWorkspacePrefs(),
          ),
        ),
      ),
    );
    await tester.pump();

    final capsule = _capsule(tester, find.byKey(kWorkspaceCompactBackKey));
    // The bar pads 8 pt; the capsule should start there, not near the middle.
    expect(
      capsule.left,
      lessThanOrEqualTo(8 + 12),
      reason: 'the back bar asks for centerLeft; the capsule must obey',
    );
    expect(
      capsule.width,
      lessThan(640 / 2),
      reason: 'the capsule is sized to its label, not stretched',
    );
  });

  testWidgets('a bare inline button in a wide left-aligned slot stays left', (
    tester,
  ) async {
    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: Center(
          child: SizedBox(
            width: 400,
            height: 60,
            child: Align(
              alignment: Alignment.centerLeft,
              child: InlineActionButton(
                key: const Key('probe-button'),
                label: 'Probe',
                icon: CupertinoIcons.add,
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final slot = tester.getRect(find.byType(Align).last);
    final capsule = _capsule(tester, find.byKey(const Key('probe-button')));
    expect(
      capsule.left - slot.left,
      lessThanOrEqualTo(1),
      reason: 'the button must honour its parent\'s alignment',
    );
    expect(capsule.width, lessThan(slot.width / 2));
  });
}
