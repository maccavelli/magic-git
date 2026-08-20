// P2 wiring: with a TabsHost present (TabsController.current set), picking a
// repository in the connections manager opens it in a tab and connects in THAT
// tab's container — not the panel's ambient session. A blank landing tab is
// reused for the first pick.

import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/switcher/connection_switcher.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Records connect attempts against the tab container it lives in.
class _RecordingConnection extends ConnectionController {
  final connected = <(String, String?)>[];
  @override
  ConnectionState build() => const ConnectionState();
  @override
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    connected.add((conn.id, repoPath));
  }
}

ProviderContainer _tabContainer(List<Override> overrides) => ProviderContainer(
  retry: (_, _) => null,
  overrides: [
    connectionProvider.overrideWith(_RecordingConnection.new),
    ...overrides,
  ],
);

void main() {
  testWidgets(
    'picking an SSH repo fills the blank tab and connects in its container',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = TabsController(containerFactory: _tabContainer);
      controller.ensureInitialTab();
      TabsController.current = controller;
      addTearDown(() {
        TabsController.current = null;
        controller.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedConnectionsProvider.overrideWith(
              (ref) async => const [
                SavedConnection(
                  id: 'c1',
                  label: 'Prod',
                  host: 'h',
                  port: 22,
                  username: 'u',
                  repoPath: '/srv/alpha',
                  repoPaths: ['/srv/alpha', '/srv/beta'],
                ),
              ],
            ),
            savedLocalReposProvider.overrideWith((ref) async => const []),
          ],
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(),
          ),
        ),
      );
      // Push the panel as a real route so picking a repo can pop it.
      final ctx = tester.element(find.byType(SizedBox));
      unawaited(
        Navigator.of(ctx).push(
          PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => const ConnectionsPanel(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the host, then pick a repository.
      await tester.tap(find.text('Prod'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();

      // The blank landing tab was reused (not duplicated) and now carries the
      // picked repo, connected in its own container.
      expect(controller.tabs, hasLength(1));
      final tab = controller.tabs.single;
      expect(tab.connectionId, 'c1');
      expect(tab.repoPath, '/srv/beta');
      final rec =
          tab.container.read(connectionProvider.notifier)
              as _RecordingConnection;
      expect(rec.connected, [('c1', '/srv/beta')]);
      expect(
        find.byType(ConnectionsPanel),
        findsNothing,
        reason: 'picking a repo closes the panel',
      );
    },
  );

  testWidgets(
    'picking a second repo opens a new tab (does not reuse the first)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = TabsController(containerFactory: _tabContainer);
      controller.ensureInitialTab();
      // First tab already holds a repo, so the next pick must open its own tab.
      controller.openOrFocus(
        connectionId: 'c1',
        repoPath: '/srv/alpha',
        connect: (c) => c.read(connectionProvider.notifier),
      );
      TabsController.current = controller;
      addTearDown(() {
        TabsController.current = null;
        controller.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedConnectionsProvider.overrideWith(
              (ref) async => const [
                SavedConnection(
                  id: 'c1',
                  label: 'Prod',
                  host: 'h',
                  port: 22,
                  username: 'u',
                  repoPath: '/srv/alpha',
                  repoPaths: ['/srv/alpha', '/srv/beta'],
                ),
              ],
            ),
            savedLocalReposProvider.overrideWith((ref) async => const []),
          ],
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(),
          ),
        ),
      );
      final ctx = tester.element(find.byType(SizedBox));
      unawaited(
        Navigator.of(ctx).push(
          PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => const ConnectionsPanel(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Prod'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();

      expect(controller.tabs, hasLength(2));
      expect(controller.active!.repoPath, '/srv/beta');
      expect(controller.tabs.first.repoPath, '/srv/alpha');
    },
  );
}
