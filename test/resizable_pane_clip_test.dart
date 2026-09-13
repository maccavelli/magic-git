// The navigator pane must contain whatever it holds.
//
// A `SizedBox` bounds layout, not painting: a `Flex` that overflows its
// constraint still paints the excess OUTSIDE its bounds, which is how a
// too-wide worktree row came to draw across the divider and over the detail
// pane (MADR 0049 F6). Bounding the row fixed that row; clipping the pane is
// what makes any FUTURE overflow truncate at the divider instead of scribbling
// on the canvas.
//
// This guards containment, not correctness — an overflow still throws in a
// widget test, and `worktree_row_overflow_test.dart` is what keeps overflow
// from becoming normal.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/features/common/resizable_master_detail.dart';

/// A child that deliberately asks for more than the pane can give it.
const _leadingKey = ValueKey('leading-child');
const double _paneExtent = 200;
const double _overWide = 900;

Future<void> _pump(
  WidgetTester tester, {
  required Axis axis,
  required double childExtent,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(1200, 800)),
        child: SizedBox(
          width: 1200,
          height: 800,
          child: ResizablePanePair(
            axis: axis,
            extent: _paneExtent,
            minExtent: 100,
            maxExtent: 600,
            trailingFloor: 100,
            defaultExtent: _paneExtent,
            onCommit: (_) {},
            leading: SizedBox(
              key: _leadingKey,
              width: axis == Axis.horizontal ? childExtent : 100,
              height: axis == Axis.horizontal ? 100 : childExtent,
            ),
            trailing: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The `ClipRect` the pane wraps its leading child in, if there is one.
///
/// Asserted structurally rather than through the `paints` matcher: the pane is
/// a `Stack`, and `paints..clipRect()` there matches the whole subtree's paint
/// order rather than this pane's own clip, so it would pass for a clip the
/// trailing side contributed. Finding the `ClipRect` that is an ancestor of the
/// leading child — and checking its SIZE — names exactly the widget under test.
Finder _leadingClip() =>
    find.ancestor(of: find.byKey(_leadingKey), matching: find.byType(ClipRect));

void main() {
  testWidgets('an over-wide leading child is clipped at the pane edge', (
    tester,
  ) async {
    await _pump(tester, axis: Axis.horizontal, childExtent: _overWide);

    final clip = _leadingClip();
    expect(
      clip,
      findsOneWidget,
      reason:
          'the leading pane paints its child unclipped, so an overflow '
          'draws across the divider onto the canvas (MADR 0049 F6)',
    );
    // The clip is only containment if it is the size of the PANE. A ClipRect
    // sized to the over-wide child would clip nothing.
    expect(tester.getSize(clip.first).width, _paneExtent);
  });

  testWidgets('the same holds on the vertical axis', (tester) async {
    await _pump(tester, axis: Axis.vertical, childExtent: _overWide);

    final clip = _leadingClip();
    expect(clip, findsOneWidget);
    expect(tester.getSize(clip.first).height, _paneExtent);
  });

  testWidgets('a leading child that fits is unaffected', (tester) async {
    await _pump(tester, axis: Axis.horizontal, childExtent: 50);

    // The control: the clip is unconditional, so it is still there — what this
    // case proves is that clipping costs a fitting child nothing, and that the
    // over-wide cases above are not passing for some unrelated reason.
    expect(_leadingClip(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
