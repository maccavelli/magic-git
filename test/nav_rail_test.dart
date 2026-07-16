// The NavRail (custom replacement for macos_ui SidebarItems): idle it renders
// the tab list and switches on tap; while a drag is live it lights up + relabels
// the tabs that would accept the payload.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drag_state.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';

const _items = [
  NavRailItem(
    icon: CupertinoIcons.folder,
    label: 'Repository',
    zone: DropZoneId.repository,
  ),
  NavRailItem(
    icon: CupertinoIcons.clock,
    label: 'History',
    zone: DropZoneId.history,
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

const _branch = DragRef(
  GitRef(
    name: 'refs/heads/feature',
    oid: 'a1b2c3d4e5f6',
    isHead: false,
    subject: 's',
  ),
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  int currentIndex = 0,
  ValueChanged<int>? onChanged,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 260,
          height: 600,
          child: NavRail(
            currentIndex: currentIndex,
            onChanged: onChanged ?? (_) {},
            items: _items,
            selectPage: (_) {},
            refresh: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('idle: renders every tab and switches on tap', (tester) async {
    var tapped = -1;
    await _pump(tester, currentIndex: 2, onChanged: (i) => tapped = i);

    for (final label in const [
      'Repository',
      'History',
      'Branches',
      'Stashes',
      'Worktrees',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('Stashes'));
    expect(tapped, 3); // Stashes is the 4th item
  });

  testWidgets('dragging a commit lights up + relabels only Branches', (
    tester,
  ) async {
    final container = await _pump(tester);
    container.read(dragStateProvider.notifier).begin(_commit);
    await tester.pump();

    // The eligible tab relabels to its action verb...
    expect(find.text('New branch'), findsOneWidget);
    expect(find.text('Branches'), findsNothing);
    // ...and no other tab claims an action.
    expect(find.text('New worktree'), findsNothing);
    expect(find.text('Stashes'), findsOneWidget); // still itself, just dimmed
  });

  testWidgets('dragging a branch lights up + relabels only Worktrees', (
    tester,
  ) async {
    final container = await _pump(tester);
    container.read(dragStateProvider.notifier).begin(_branch);
    await tester.pump();

    expect(find.text('New worktree'), findsOneWidget);
    expect(find.text('Worktrees'), findsNothing);
    expect(find.text('New branch'), findsNothing);
  });

  testWidgets('ending the drag restores the resting labels', (tester) async {
    final container = await _pump(tester);
    final notifier = container.read(dragStateProvider.notifier);
    notifier.begin(_commit);
    await tester.pump();
    expect(find.text('New branch'), findsOneWidget);

    notifier.end();
    await tester.pump();
    expect(find.text('New branch'), findsNothing);
    expect(find.text('Branches'), findsOneWidget);
  });
}
