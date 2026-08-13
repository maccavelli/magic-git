import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/local_repo_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';
import 'package:remote_magic_git/features/tabs/saved_workspace_actions.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

class _ConnectionStore extends ConnectionStore {
  _ConnectionStore(this.connections);
  final List<SavedConnection> connections;

  @override
  Future<List<SavedConnection>> list() async => connections;
}

class _LocalStore extends LocalRepoStore {
  @override
  Future<List<SavedLocalRepo>> list() async => const [];
}

class _ThrowingConnectionStore extends ConnectionStore {
  @override
  Future<List<SavedConnection>> list() => Future.error(StateError('offline'));
}

class _Recorder extends ConnectionController {
  final calls = <String>[];

  @override
  ConnectionState build() => const ConnectionState();

  @override
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    calls.add('${conn.id}:$repoPath');
    state = ConnectionState(
      phase: ConnectionPhase.connected,
      connectionId: conn.id,
      repoPath: repoPath,
      repoPaths: conn.allRepoPaths,
      sessionEpoch: 1,
    );
  }
}

ProviderContainer _tabContainer(List<Override> overrides) => ProviderContainer(
  retry: (_, _) => null,
  overrides: [connectionProvider.overrideWith(_Recorder.new), ...overrides],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'opening a set dedupes, preserves successful tabs, reports missing members, '
    'and restores the requested active tab',
    (tester) async {
      const connection = SavedConnection(
        id: 'ssh-1',
        label: 'Prod',
        host: 'host',
        port: 22,
        username: 'user',
        repoPath: '/existing',
        repoPaths: ['/existing', '/new'],
      );
      final tabs = TabsController(containerFactory: _tabContainer);
      addTearDown(tabs.dispose);
      tabs.ensureInitialTab();
      final existing = tabs.openOrFocus(
        connectionId: 'ssh-1',
        repoPath: '/existing',
        savedKind: SavedRepositoryKind.ssh,
        connect: (_) {},
      );
      TabsController.current = tabs;
      addTearDown(() => TabsController.current = null);

      late BuildContext context;
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionStoreProvider.overrideWithValue(
              _ConnectionStore(const [connection]),
            ),
            localRepoStoreProvider.overrideWithValue(_LocalStore()),
          ],
          child: Consumer(
            builder: (buildContext, widgetRef, _) {
              context = buildContext;
              ref = widgetRef;
              return const SizedBox();
            },
          ),
        ),
      );

      const set = SavedWorkspaceSet(
        id: 'daily',
        displayName: 'Daily',
        repositories: [
          SavedWorkspaceRepositoryRef(
            kind: SavedRepositoryKind.ssh,
            savedId: 'ssh-1',
            repoPath: '/existing',
            tabAlias: 'Existing',
          ),
          SavedWorkspaceRepositoryRef(
            kind: SavedRepositoryKind.ssh,
            savedId: 'missing',
            repoPath: '/gone',
          ),
          SavedWorkspaceRepositoryRef(
            kind: SavedRepositoryKind.ssh,
            savedId: 'ssh-1',
            repoPath: '/new',
            tabAlias: 'New',
          ),
        ],
        activeIndex: 2,
      );

      final report = await openSavedWorkspaceSet(context, ref, set);

      expect(report.focusedCount, 1);
      expect(report.openedCount, 1);
      expect(report.failures, hasLength(1));
      expect(report.failures.single.repository.repoPath, '/gone');
      expect(tabs.tabs, hasLength(2));
      expect(tabs.aliasFor(existing), 'Existing');
      expect(tabs.aliasFor(tabs.active!), 'New');
      expect(tabs.active!.repoPath, '/new');
      final recorder =
          tabs.active!.container.read(connectionProvider.notifier) as _Recorder;
      expect(recorder.calls, ['ssh-1:/new']);
    },
  );

  testWidgets('a full tab controller reports capacity without connecting', (
    tester,
  ) async {
    const connection = SavedConnection(
      id: 'overflow',
      label: 'Overflow',
      host: 'host',
      port: 22,
      username: 'user',
      repoPath: '/overflow',
    );
    final tabs = TabsController(containerFactory: _tabContainer);
    addTearDown(tabs.dispose);
    tabs.ensureInitialTab();
    for (var index = 0; index < TabsController.maxTabs; index++) {
      tabs.openOrFocus(
        connectionId: 'id-$index',
        repoPath: '/repo-$index',
        savedKind: SavedRepositoryKind.ssh,
        connect: (_) {},
      );
    }
    TabsController.current = tabs;
    addTearDown(() => TabsController.current = null);
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionStoreProvider.overrideWithValue(
            _ConnectionStore(const [connection]),
          ),
          localRepoStoreProvider.overrideWithValue(_LocalStore()),
        ],
        child: Consumer(
          builder: (buildContext, widgetRef, _) {
            context = buildContext;
            ref = widgetRef;
            return const SizedBox();
          },
        ),
      ),
    );

    final report = await openSavedWorkspaceSet(
      context,
      ref,
      const SavedWorkspaceSet(
        id: 'overflow',
        displayName: 'Overflow',
        repositories: [
          SavedWorkspaceRepositoryRef(
            kind: SavedRepositoryKind.ssh,
            savedId: 'overflow',
            repoPath: '/overflow',
          ),
        ],
        activeIndex: 0,
      ),
    );

    expect(report.openedCount, 0);
    expect(report.failures.single.reason, contains('Maximum of 8 tabs'));
    expect(tabs.tabs, hasLength(TabsController.maxTabs));
  });

  testWidgets('store failure becomes a per-member failure report', (
    tester,
  ) async {
    final tabs = TabsController(containerFactory: _tabContainer);
    addTearDown(tabs.dispose);
    tabs.ensureInitialTab();
    TabsController.current = tabs;
    addTearDown(() => TabsController.current = null);
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionStoreProvider.overrideWithValue(_ThrowingConnectionStore()),
          localRepoStoreProvider.overrideWithValue(_LocalStore()),
        ],
        child: Consumer(
          builder: (buildContext, widgetRef, _) {
            context = buildContext;
            ref = widgetRef;
            return const SizedBox();
          },
        ),
      ),
    );

    final report = await openSavedWorkspaceSet(
      context,
      ref,
      const SavedWorkspaceSet(
        id: 'broken-store',
        displayName: 'Broken store',
        repositories: [
          SavedWorkspaceRepositoryRef(
            kind: SavedRepositoryKind.ssh,
            savedId: 'ssh-1',
            repoPath: '/repo',
          ),
        ],
        activeIndex: 0,
      ),
    );

    expect(report.failures, hasLength(1));
    expect(report.failures.single.reason, contains('no longer available'));
  });
}
