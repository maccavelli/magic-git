// End-to-end: dragging a panel item onto a nav-rail tab dispatches its workflow.
// A commit dropped on Branches opens the "new branch from commit" prompt; the
// path runs through the drag source -> DropZone -> registry -> action handler.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';

const _repo = '/srv/repo';

/// Minimal connection state so the DropZone sees an active repoPath.
class _FakeConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected, repoPath: _repo);
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
    icon: CupertinoIcons.arrow_branch,
    label: 'Branches',
    zone: DropZoneId.branches,
  ),
  NavRailItem(
    icon: CupertinoIcons.tree,
    label: 'Worktrees',
    zone: DropZoneId.worktrees,
  ),
];

Future<void> _dragOnto(WidgetTester tester, Finder source, Finder target) async {
  final from = tester.getCenter(source);
  final to = tester.getCenter(target);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // exceed touch slop
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dropping a commit on Branches opens the new-branch prompt', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectionProvider.overrideWith(_FakeConnection.new)],
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Row(
            children: [
              // The drag source — stands in for a history commit row.
              const DragItemDraggable(
                item: _commit,
                immediate: true,
                child: SizedBox(
                  width: 120,
                  height: 44,
                  child: Center(child: Text('SOURCE')),
                ),
              ),
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
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _dragOnto(tester, find.text('SOURCE'), find.text('Branches'));

    // The registry ran the single non-destructive action: the seeded prompt.
    expect(find.text('New branch from commit'), findsOneWidget);
  });
}
