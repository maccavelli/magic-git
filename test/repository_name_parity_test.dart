// MADR 0052: in one tab, the tab title, the sidebar Repository row, a pane's
// status bar and the window title all show the same repository name — the
// tab alias when set, else the directory — and a saved repository label
// renames none of them.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_store.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:remote_magic_git/features/switcher/current_repo_indicator.dart';
import 'package:remote_magic_git/features/tabs/tab_strip.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:remote_magic_git/features/tabs/tabs_host.dart';
import 'package:remote_magic_git/features/tabs/tabs_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/srv/backend-src';

class _StubConnection extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    backend: ConnectionBackend.ssh,
    host: 'build01.example.com',
    connectionId: 'c1',
    connectionLabel: 'Build box',
    repoPath: _repo,
    repoPaths: [_repo],
  );
}

const _saved = SavedConnection(
  id: 'c1',
  label: 'Build box',
  host: 'build01.example.com',
  port: 22,
  username: 'deploy',
  repoPath: _repo,
  repoLabels: {_repo: 'Website'},
);

/// One controller with the tab under test on [_repo] and a second tab, so the
/// strip renders (it hides with a single tab), pumped with that tab's own
/// container around the strip, the Repository row and the Stashes pane.
Future<({TabsController controller, RepoTab tab})> _pump(
  WidgetTester tester,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final controller = TabsController(
    workspaceStore: SavedWorkspaceStore(),
    containerFactory: (overrides) => ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionProvider.overrideWith(_StubConnection.new),
        statusProvider.overrideWith(
          (ref, repo) async => GitStatus(
            branch: const GitBranchInfo(head: 'main'),
            files: const [],
          ),
        ),
        stashesProvider(_repo).overrideWith((ref) async => const []),
        savedConnectionsProvider.overrideWith((ref) async => const [_saved]),
        repoWatchProvider(
          _repo,
        ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        ...overrides,
      ],
    ),
  );
  TabsController.current = controller;
  addTearDown(() {
    TabsController.current = null;
    controller.dispose();
  });
  await controller.aliasesReady;
  controller.ensureInitialTab();
  final tab = controller.openOrFocus(
    connectionId: 'c1',
    repoPath: _repo,
    savedKind: SavedRepositoryKind.ssh,
    connect: (_) {},
  );
  controller.openOrFocus(
    connectionId: 'c1',
    repoPath: '/srv/other',
    savedKind: SavedRepositoryKind.ssh,
    connect: (_) {},
  );
  controller.activate(tab.id);

  await tester.pumpWidget(
    TabsScope(
      controller: controller,
      child: UncontrolledProviderScope(
        container: tab.container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: Column(
            children: [
              TabStrip(),
              SizedBox(height: 60, child: CurrentRepoIndicator()),
              Expanded(child: StashView(repoPath: _repo)),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller: controller, tab: tab);
}

/// Asserts all four surfaces show [name].
void _expectEverywhere(WidgetTester tester, RepoTab tab, String name) {
  expect(
    find.descendant(of: find.byType(TabStrip), matching: find.text(name)),
    findsOneWidget,
    reason: 'tab title',
  );
  expect(
    find.descendant(
      of: find.byType(CurrentRepoIndicator),
      matching: find.text(name),
    ),
    findsOneWidget,
    reason: 'Repository row',
  );
  expect(find.text('Repository: $name'), findsOneWidget, reason: 'status bar');
  expect(
    tab.container.read(windowTitleProvider),
    startsWith('$name '),
    reason: 'window title',
  );
}

void main() {
  testWidgets('P1 with no alias every surface shows the directory', (
    tester,
  ) async {
    final (controller: _, :tab) = await _pump(tester);
    _expectEverywhere(tester, tab, 'backend-src');
  });

  testWidgets('P2 with an alias every surface shows the alias', (tester) async {
    final (:controller, :tab) = await _pump(tester);
    await controller.setAlias(tab, 'Backend');
    await tester.pumpAndSettle();
    _expectEverywhere(tester, tab, 'Backend');
  });

  testWidgets('P3 a saved repository label renames no surface', (tester) async {
    final (:controller, :tab) = await _pump(tester);
    expect(find.text('Website'), findsNothing);
    expect(find.text('Repository: Website'), findsNothing);
    await controller.setAlias(tab, 'Backend');
    await tester.pumpAndSettle();
    expect(find.text('Website'), findsNothing);
    expect(find.text('Repository: Website'), findsNothing);
  });
}
