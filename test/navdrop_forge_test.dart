// A1 dispatch: dragging a local branch onto the Forge tab seeds the Forge
// panel's inline create form with that branch and navigates to the tab — or
// reports that the repo has no forge. Providers are stubbed so no gh/glab/git
// runs.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';

const _repo = '/srv/repo';

class _FakeConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected, repoPath: _repo);
}

const _branch = DragRef(
  GitRef(
    name: 'refs/heads/feature',
    oid: 'a1b2c3d4e5f6',
    isHead: false,
    subject: 's',
  ),
);

const _items = [
  NavRailItem(
    icon: CupertinoIcons.cloud,
    label: 'Forge',
    zone: DropZoneId.forge,
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
  await gesture.moveBy(const Offset(0, -20));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<(ProviderContainer, List<int>)> _pump(
  WidgetTester tester,
  Forge forge,
) async {
  final selected = <int>[];
  final container = ProviderContainer(
    overrides: [
      connectionProvider.overrideWith(_FakeConnection.new),
      forgeProvider.overrideWith((ref, repo) async => forge),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            const DragItemDraggable(
              item: _branch,
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
                selectPage: selected.add,
                refresh: () {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container, selected);
}

void main() {
  testWidgets(
    'a branch dropped on Forge (GitHub) seeds the inline create form and '
    'navigates to the Forge tab',
    (tester) async {
      final (container, selected) = await _pump(tester, Forge.github);
      await _dragOnto(tester, find.text('SOURCE'), find.text('Forge'));

      // The drop hands the branch to the Forge panel via the seed provider
      // (the panel — not mounted in this harness — consumes and clears it)
      // and brings the Forge tab forward.
      expect(
        container.read(forgeCreateSeedProvider),
        (repoPath: _repo, branch: 'feature'),
      );
      expect(selected, [DropZoneId.forge.pageIndex]);
    },
  );

  testWidgets('a branch dropped on Forge with no forge reports it', (
    tester,
  ) async {
    final (container, selected) = await _pump(tester, Forge.none);
    await _dragOnto(tester, find.text('SOURCE'), find.text('Forge'));

    expect(container.read(forgeCreateSeedProvider), isNull);
    expect(selected, isEmpty);
    expect(
      find.textContaining('No GitHub or GitLab remote'),
      findsOneWidget,
    );
  });
}
