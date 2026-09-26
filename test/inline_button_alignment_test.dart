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

const _probeKey = Key('probe-button');
const _referenceKey = Key('reference-capsule');

/// The button's shape before Phase 3, for comparison (MADR 0068 Amendment
/// 0068.7): a bare [Center] that fills whatever width it is offered, around a
/// capsule of the real button's width.
class _FillsLikeBefore extends StatelessWidget {
  const _FillsLikeBefore({required this.capsuleWidth});
  final double capsuleWidth;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 28),
    child: Center(
      child: SizedBox(key: _referenceKey, width: capsuleWidth, height: 18),
    ),
  );
}

/// A kind of parent the call sites put the button in, by the width it offers
/// and where it puts a child narrower than that.
typedef _Parent = Widget Function(Widget button);

final Map<String, _Parent> _parents = {
  'Row': (b) => Row(children: [b]),
  'Wrap (start)': (b) => Wrap(children: [b]),
  'Wrap (end)': (b) => Wrap(alignment: WrapAlignment.end, children: [b]),
  'Column (center)': (b) => Column(children: [b]),
  'Column (start)': (b) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [b]),
  'Column (stretch)': (b) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [b]),
  'Align (centerLeft)': (b) => Align(alignment: Alignment.centerLeft, child: b),
  'Center': (b) => Center(child: b),
  'Expanded in a Row': (b) => Row(children: [Expanded(child: b)]),
  'Horizontal ListView': (b) =>
      ListView(scrollDirection: Axis.horizontal, children: [b]),
};

Future<Rect> _layOut(WidgetTester tester, Widget child, Key capsuleKey) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 400, height: 60, child: child),
      ),
    ),
  );
  await tester.pump();
  return capsuleKey == _probeKey
      ? _capsule(tester, find.byKey(_probeKey))
      : tester.getRect(find.byKey(capsuleKey));
}

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

  // Amendment 0068.7 (deviation D5): which kinds of parent see the capsule
  // move, measured against the old shape rather than read from the code. A
  // parent moves it only when it offers a bounded, loose width and places a
  // narrower child anywhere but the centre. The amendment's call-site list is
  // this table applied to each site's nearest layout-deciding parent.
  testWidgets('the parents in which the capsule moves are exactly these', (
    tester,
  ) async {
    Widget button() => InlineActionButton(
      key: _probeKey,
      label: 'Probe',
      icon: CupertinoIcons.add,
      onPressed: () {},
    );
    final capsuleWidth = (await _layOut(
      tester,
      Row(children: [button()]),
      _probeKey,
    )).width;

    final moved = <String>{};
    for (final MapEntry(key: name, value: parent) in _parents.entries) {
      final now = await _layOut(tester, parent(button()), _probeKey);
      final before = await _layOut(
        tester,
        parent(_FillsLikeBefore(capsuleWidth: capsuleWidth)),
        _referenceKey,
      );
      if ((now.left - before.left).abs() > 0.5) moved.add(name);
    }

    expect(moved, {
      'Wrap (start)',
      'Wrap (end)',
      'Column (start)',
      'Align (centerLeft)',
    });
  });
}
