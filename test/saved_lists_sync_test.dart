// Cross-tab saved-list coherence: a ConnectionStore/LocalRepoStore write in one
// tab (announced via StoreBus) refreshes savedConnectionsProvider /
// savedLocalReposProvider in EVERY tab, fanned out by TabsController.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/local_repo_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/core/storage/store_bus.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubConn extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState();
}

class _CountingConnStore extends ConnectionStore {
  int listCalls = 0;
  @override
  Future<List<SavedConnection>> list() async {
    listCalls++;
    return const [];
  }
}

class _CountingLocalStore extends LocalRepoStore {
  int listCalls = 0;
  @override
  Future<List<SavedLocalRepo>> list() async {
    listCalls++;
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a connection-store write refreshes savedConnectionsProvider in every tab',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _CountingConnStore();
      final c = TabsController(
        containerFactory: (overrides) => ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            connectionStoreProvider.overrideWithValue(store),
            connectionProvider.overrideWith(_StubConn.new),
            ...overrides,
          ],
        ),
      );
      addTearDown(c.dispose);
      final t1 = c.ensureInitialTab();
      final t2 = c.openOrFocus(
        connectionId: 'x',
        repoPath: '/y',
        connect: (_) {},
      );

      await t1.container.read(savedConnectionsProvider.future);
      await t2.container.read(savedConnectionsProvider.future);
      final before = store.listCalls;

      StoreBus.instance.notifyConnectionsChanged();
      await pumpEventQueue();
      await t1.container.read(savedConnectionsProvider.future);
      await t2.container.read(savedConnectionsProvider.future);

      expect(
        store.listCalls,
        greaterThan(before),
        reason: 'both tabs re-listed after the cross-tab write',
      );
    },
  );

  test(
    'a local-repo-store write refreshes savedLocalReposProvider in every tab',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _CountingLocalStore();
      final c = TabsController(
        containerFactory: (overrides) => ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            localRepoStoreProvider.overrideWithValue(store),
            connectionProvider.overrideWith(_StubConn.new),
            ...overrides,
          ],
        ),
      );
      addTearDown(c.dispose);
      final t1 = c.ensureInitialTab();
      final t2 = c.openOrFocus(
        connectionId: 'x',
        repoPath: '/y',
        connect: (_) {},
      );

      await t1.container.read(savedLocalReposProvider.future);
      await t2.container.read(savedLocalReposProvider.future);
      final before = store.listCalls;

      StoreBus.instance.notifyLocalReposChanged();
      await pumpEventQueue();
      await t1.container.read(savedLocalReposProvider.future);
      await t2.container.read(savedLocalReposProvider.future);

      expect(store.listCalls, greaterThan(before));
    },
  );
}
