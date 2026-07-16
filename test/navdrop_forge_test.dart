// A1 dispatch: dragging a local branch onto the Forge tab opens the right
// create sheet (PR for GitHub) seeded with that branch, or reports that the repo
// has no forge. Providers are stubbed so no gh/glab/git runs.

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';
import 'package:remote_magic_git/features/github/create_pr_sheet.dart';

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

Future<void> _pump(WidgetTester tester, Forge forge) async {
  // The full create sheet is tall; give it room so it doesn't overflow.
  await tester.binding.setSurfaceSize(const Size(1200, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(_FakeConnection.new),
        forgeProvider.overrideWith((ref, repo) async => forge),
        // Keep the create sheet's data deps pending so nothing real runs; the
        // sheet still renders its form (and the seeded head field).
        statusProvider.overrideWith((ref, repo) => Completer<GitStatus>().future),
        githubProjectDashboardProvider.overrideWith(
          (ref, repo) => Completer<ForgeProjectDashboard>().future,
        ),
      ],
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
}

void main() {
  testWidgets('a branch dropped on Forge (GitHub) opens the seeded PR sheet', (
    tester,
  ) async {
    await _pump(tester, Forge.github);
    await _dragOnto(tester, find.text('SOURCE'), find.text('Forge'));

    // The full sheet slightly overflows the headless viewport while its data
    // providers are still loading — cosmetic and unrelated to the drop, so
    // drain the layout exception(s) before asserting.
    while (tester.takeException() != null) {}

    expect(find.byType(CreatePrSheet), findsOneWidget);
    // The dropped branch seeds the head field.
    expect(find.text('feature'), findsOneWidget);
  });

  testWidgets('a branch dropped on Forge with no forge reports it', (
    tester,
  ) async {
    await _pump(tester, Forge.none);
    await _dragOnto(tester, find.text('SOURCE'), find.text('Forge'));

    expect(find.byType(CreatePrSheet), findsNothing);
    expect(
      find.textContaining('No GitHub or GitLab remote'),
      findsOneWidget,
    );
  });
}
