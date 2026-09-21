// MADR 0064 F2 (Confirmation 2): the drag image must never hide the drop
// target under the pointer.
//
// Over an accepting target the lifted snapshot collapses to a compact chip
// whose top-left sits at pointer + kDragChipPointerOffset, so neither the
// pointer nor the hovered row is covered; off any target (or once Esc cancels
// the drag) the full lifted snapshot returns and a cancelled release still
// flies home. The hovered nav-rail row also carries a border, so the cue does
// not rest on a 16-point alpha difference alone.
//
// Real gestures only (tester.startGesture / moveTo): the snapshot is captured
// under fake async, so the ghost geometry measured here is the real one.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';

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

const _items = [
  NavRailItem(
    icon: CupertinoIcons.folder,
    label: 'Repository',
    zone: DropZoneId.repository,
  ),
  NavRailItem(
    icon: CupertinoIcons.arrow_branch,
    label: 'Branches',
    zone: DropZoneId.branches,
  ),
  NavRailItem(
    icon: CupertinoIcons.tray_2,
    label: 'Stashes',
    zone: DropZoneId.stashes,
  ),
  NavRailItem(
    icon: CupertinoIcons.tree,
    label: 'Worktrees',
    zone: DropZoneId.worktrees,
  ),
];

const _sourceKey = ValueKey('source-row');

/// A point well clear of the rail and the source row: no drop target here.
const _neutral = Offset(1000, 400);

/// Long enough for any lift/collapse animation to settle while the pointer
/// is held.
const _settle = Duration(milliseconds: 300);

/// The rail (240 px, as the shell's minimum sidebar) beside a 900 x 52 source
/// row standing in for a History commit row at zoom 1.0.
Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionProvider.overrideWith(_FakeConnection.new)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 240,
              height: 600,
              child: NavRail(
                currentIndex: 0,
                onChanged: (_) {},
                items: _items,
                selectPage: (_) {},
                refresh: () {},
              ),
            ),
            const DragItemDraggable(
              item: _commit,
              immediate: true,
              child: SizedBox(
                key: _sourceKey,
                width: 900,
                height: 52,
                child: ColoredBox(
                  color: Color(0xFF3E597B),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('SOURCE commit row'),
                  ),
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

/// Presses the source row [grabDx] px in from its left edge and lifts it.
Future<TestGesture> _lift(WidgetTester tester, {required double grabDx}) async {
  final source = tester.getRect(find.byKey(_sourceKey));
  final gesture = await tester.startGesture(
    Offset(source.left + grabDx, source.center.dy),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // past the drag slop
  await tester.pump(_settle);
  return gesture;
}

/// Holds the drag over the centre of the "New branch" rail row and returns the
/// pointer position.
Future<Offset> _hoverNewBranch(WidgetTester tester, TestGesture gesture) async {
  final pointer = tester.getCenter(_navRowOf('New branch'));
  await gesture.moveTo(pointer);
  await tester.pump(_settle);
  return pointer;
}

/// The nav-rail row's decorated container (the one carrying its background).
Finder _navRowOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Container)).first;

BoxDecoration _decorationOf(WidgetTester tester, String label) =>
    tester.widget<Container>(_navRowOf(label)).decoration! as BoxDecoration;

/// The drag image. Exactly one cell chrome may be on screen at a time.
Rect _ghost(WidgetTester tester) {
  expect(find.byType(DragCellChrome), findsOneWidget);
  return tester.getRect(find.byType(DragCellChrome));
}

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await gesture.moveTo(_neutral);
  await tester.pump(_settle);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('grab at x = 300, held over "New branch"', () {
    testWidgets('(a) the drag image does not contain the pointer', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      final pointer = await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      expect(
        ghost.contains(pointer),
        isFalse,
        reason: 'ghost $ghost covers the pointer $pointer',
      );

      await _release(tester, gesture);
    });

    testWidgets('(b) the drag image does not overlap the hovered row', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      final row = tester.getRect(_navRowOf('New branch'));
      final overlap = ghost.intersect(row);
      expect(
        overlap.width <= 0 || overlap.height <= 0,
        isTrue,
        reason: 'ghost $ghost overlaps the hovered row $row by $overlap',
      );

      await _release(tester, gesture);
    });

    testWidgets('(c) only the hovered row carries a border', (tester) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      expect(
        _decorationOf(tester, 'New branch').border,
        isNotNull,
        reason: 'the hovered (activeDrop) row must carry a border',
      );
      expect(
        _decorationOf(tester, 'New worktree').border,
        isNull,
        reason: 'an eligible row that is not hovered must not',
      );

      await _release(tester, gesture);
    });

    testWidgets('(f) the chip is capped and sits at the pointer offset', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      final pointer = await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      // The lift's 1.03 scale is allowed for in both checks.
      expect(ghost.width, lessThanOrEqualTo(kDragChipMaxWidth * 1.03 + 1));
      final expected = pointer + kDragChipPointerOffset;
      expect(ghost.left, closeTo(expected.dx, 5));
      expect(ghost.top, closeTo(expected.dy, 5));

      await _release(tester, gesture);
    });

    testWidgets('(d) moving off the target restores the full lifted image', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      await gesture.moveTo(_neutral);
      await tester.pump(_settle);
      expect(_ghost(tester).width, greaterThanOrEqualTo(400));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('(e) Esc while hovering restores the full image and the '
        'release still flies home', (tester) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(_settle);
      expect(_ghost(tester).width, greaterThanOrEqualTo(400));

      await gesture.up();
      await tester.pump();
      expect(find.byType(SnapBackFlight), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byType(SnapBackFlight), findsNothing);
    });
  });

  group('left-edge grab (x = 40), held over "New branch"', () {
    testWidgets('(a) the drag image does not contain the pointer', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 40);
      final pointer = await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      expect(
        ghost.contains(pointer),
        isFalse,
        reason: 'ghost $ghost covers the pointer $pointer',
      );

      await _release(tester, gesture);
    });

    testWidgets('(b) the drag image does not overlap the hovered row', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 40);
      await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      final row = tester.getRect(_navRowOf('New branch'));
      final overlap = ghost.intersect(row);
      expect(
        overlap.width <= 0 || overlap.height <= 0,
        isTrue,
        reason: 'ghost $ghost overlaps the hovered row $row by $overlap',
      );

      await _release(tester, gesture);
    });
  });
}
