// MADR 0064 F2: a drop target that is removed from the tree while it holds
// the drag's hover must give the hover back.
//
// Flutter never calls onLeave on an unmounted target, so without an owner
// that releases on dispose the drag image would stay a compact chip over
// empty space until the release. Ownership also means removing a target that
// no longer holds the hover must not take it from the target that does.
//
// The release lands in the frame after the removal: the target is disposed
// while the widget tree is locked, where the drag image cannot be marked for
// rebuild, so the clear is deferred to the end of that frame.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/drop_zone.dart';

/// Minimal connection state so a DropZone sees an active repoPath.
class _FakeConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected, repoPath: '/r');
}

const _commit = DragCommit(
  GitCommit(
    hash: 'a1b2c3d4e5f6',
    shortHash: 'a1b2c3d',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-16T10:00',
    parents: [],
    subject: 'a change',
  ),
);

const _sourceKey = ValueKey('source-row');

/// A point well clear of the targets and the source row.
const _neutral = Offset(1000, 500);

/// Long enough for the lift animation to settle while the pointer is held.
const _settle = Duration(milliseconds: 300);

/// The compact chip's widest on-screen size (the lift's 1.03 scale allowed).
const _chipMaxOnScreen = kDragChipMaxWidth * 1.03 + 1;

/// Two Branches drop zones (both accept a dragged commit) above a 900 x 52
/// source row. [visible] names the targets currently in the tree, so a test
/// can remove one mid-drag while the pointer is still held.
Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<Set<String>> visible,
) async {
  tester.view.physicalSize = const Size(1400, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionProvider.overrideWith(_FakeConnection.new)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 60,
              child: ValueListenableBuilder<Set<String>>(
                valueListenable: visible,
                builder: (context, names, _) => Row(
                  children: [
                    for (final name in const ['A', 'B'])
                      if (names.contains(name))
                        SizedBox(
                          width: 200,
                          height: 40,
                          child: DropZone(
                            key: ValueKey('zone-$name'),
                            id: DropZoneId.branches,
                            selectPage: (_) {},
                            refresh: () {},
                            builder: (context, hovering) =>
                                Center(child: Text('TARGET $name')),
                          ),
                        )
                      else
                        const SizedBox(width: 200, height: 40),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 100),
            const DragItemDraggable(
              item: _commit,
              immediate: true,
              child: SizedBox(
                key: _sourceKey,
                width: 900,
                height: 52,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('SOURCE commit row'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Presses the source row 300 px in from its left edge and lifts it.
Future<TestGesture> _lift(WidgetTester tester) async {
  final source = tester.getRect(find.byKey(_sourceKey));
  final gesture = await tester.startGesture(
    Offset(source.left + 300, source.center.dy),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // past the drag slop
  await tester.pump(_settle);
  return gesture;
}

/// The drag image's on-screen width. Exactly one cell chrome at a time.
double _ghostWidth(WidgetTester tester) {
  expect(find.byType(DragCellChrome), findsOneWidget);
  return tester.getRect(find.byType(DragCellChrome)).width;
}

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await gesture.moveTo(_neutral);
  await tester.pump(_settle);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('removing the hovered target mid-drag restores the full image', (
    tester,
  ) async {
    final visible = ValueNotifier<Set<String>>({'A', 'B'});
    addTearDown(visible.dispose);
    await _pump(tester, visible);
    final gesture = await _lift(tester);

    await gesture.moveTo(tester.getCenter(find.text('TARGET A')));
    await tester.pump(_settle);
    expect(
      _ghostWidth(tester),
      lessThanOrEqualTo(_chipMaxOnScreen),
      reason: 'precondition: over an accepting target the image is a chip',
    );

    // Remove A with the pointer still held over where it was. Flutter will
    // never call A's onLeave: only its disposal can give the hover back.
    visible.value = {'B'};
    await tester.pump(); // the frame that disposes A
    await tester.pump(); // the frame after it: the deferred release lands
    expect(find.text('TARGET A'), findsNothing);
    expect(
      _ghostWidth(tester),
      greaterThanOrEqualTo(400),
      reason: 'the removed target held the hover; the full image must return',
    );

    await _release(tester, gesture);
  });

  testWidgets('removing a target that no longer holds the hover leaves the '
      'hovered target in charge', (tester) async {
    final visible = ValueNotifier<Set<String>>({'A', 'B'});
    addTearDown(visible.dispose);
    await _pump(tester, visible);
    final gesture = await _lift(tester);

    await gesture.moveTo(tester.getCenter(find.text('TARGET A')));
    await tester.pump(_settle);
    await gesture.moveTo(tester.getCenter(find.text('TARGET B')));
    await tester.pump(_settle);
    expect(
      _ghostWidth(tester),
      lessThanOrEqualTo(_chipMaxOnScreen),
      reason: 'precondition: B now holds the hover',
    );

    visible.value = {'B'}; // dispose A, which left before B was entered
    await tester.pump();
    await tester.pump();
    expect(find.text('TARGET A'), findsNothing);
    expect(
      _ghostWidth(tester),
      lessThanOrEqualTo(_chipMaxOnScreen),
      reason: "A's disposal must not clear B's live hover",
    );

    await _release(tester, gesture);
  });
}
