// The Connections panel's "Local Repositories" section: a header + a tile
// per saved local repo, and the "Add local repository" toolbar button
// opening the picker sheet.

import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/switcher/connection_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ToolIconButton wraps MacosTooltip (not Flutter's standard Tooltip), so
// find.byTooltip doesn't match it — match on the tooltip message directly.
Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

/// Records whether `disconnect()` — the Logout button's action — was invoked.
class _FakeConnectionController extends ConnectionController {
  bool disconnectCalled = false;
  @override
  ConnectionState build() => const ConnectionState();
  @override
  Future<void> disconnect() async => disconnectCalled = true;
}

/// Pins a fixed connection state so the switcher button's label can be checked.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

/// Records connect attempts from repository clicks in the panel.
class _RecordingConnection extends ConnectionController {
  final connected = <(String, String?)>[];
  @override
  ConnectionState build() => const ConnectionState();
  @override
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    connected.add((conn.id, repoPath));
  }
}

Future<void> _pump(
  WidgetTester tester, {
  List<SavedLocalRepo> savedLocal = const [],
  List<SavedConnection> saved = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedLocalReposProvider.overrideWith((ref) async => savedLocal),
        savedConnectionsProvider.overrideWith((ref) async => saved),
        // Opening the clone/create sheets from the header must not spawn a
        // real gh for the This-Mac browse list or the auth-host prefill.
        forgeRepoListProvider.overrideWith((ref, key) async => []),
        forgeAuthHostProvider.overrideWith((ref, key) async => null),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionsPanel(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the empty state with no saved connections at all', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('No saved connections'), findsOneWidget);
    expect(find.text('Local Repositories'), findsNothing);
  });

  testWidgets(
    'shows a "Local Repositories" section with a tile per saved repo',
    (tester) async {
      await _pump(
        tester,
        savedLocal: const [
          SavedLocalRepo(id: 'l1', label: 'My Project', repoPath: '/a/b/proj'),
          SavedLocalRepo(id: 'l2', label: '', repoPath: '/a/b/other-repo'),
        ],
      );

      expect(find.text('Local Repositories'), findsOneWidget);
      expect(find.text('My Project'), findsOneWidget);
      // No label given — falls back to the folder's basename.
      expect(find.text('other-repo'), findsOneWidget);
    },
  );

  testWidgets('Local Repositories section sits above Remote Repositories', (
    tester,
  ) async {
    await _pump(
      tester,
      savedLocal: const [
        SavedLocalRepo(id: 'l1', label: 'My Project', repoPath: '/a/b/proj'),
      ],
      saved: const [
        SavedConnection(
          id: 'c1',
          label: 'Prod',
          host: 'h',
          port: 22,
          username: 'u',
          repoPath: '/srv/alpha',
        ),
      ],
    );

    final localY = tester.getTopLeft(find.text('Local Repositories')).dy;
    final remoteY = tester.getTopLeft(find.text('Remote Repositories')).dy;
    expect(
      localY,
      lessThan(remoteY),
      reason: 'local repos lead the panel; remote hosts follow',
    );
  });

  testWidgets('Add local repository opens the picker sheet', (tester) async {
    await _pump(tester);
    // Assert on the sheet's unique folder-picker row rather than its title,
    // which is a separate concern from the toolbar tooltip we tap.
    expect(find.text('Choose…'), findsNothing);

    await tester.tap(_byMacosTooltip('Add local repository'));
    await tester.pumpAndSettle();

    expect(find.text('Choose…'), findsOneWidget);
  });

  testWidgets('Clone repository opens the clone sheet (landing mode while '
      'disconnected)', (tester) async {
    await _pump(tester);
    await tester.tap(_byMacosTooltip('Clone repository'));
    await tester.pumpAndSettle();

    expect(find.text('Clone repository'), findsOneWidget);
    // Landing wizard: 'Destination' appears as the step's section caption
    // and in the breadcrumb indicator.
    expect(find.text('Destination'), findsWidgets);
  });

  testWidgets('Create repository opens the create sheet', (tester) async {
    await _pump(tester);
    await tester.tap(_byMacosTooltip('Create repository'));
    await tester.pumpAndSettle();

    expect(find.text('Create repository'), findsOneWidget);
    // Disconnected → landing variant: the wizard opens on Destination.
    expect(find.text('Destination'), findsWidgets);
    expect(find.text('This Mac'), findsWidgets);
  });

  testWidgets(
    'connections are disclosure groups: repositories stay hidden until the '
    'host row is expanded, and clicking a repository (not the host) connects',
    (tester) async {
      final recorder = _RecordingConnection();
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => recorder),
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
      // Push the panel as a real route: clicking a repository pops the
      // sheet, which needs something underneath.
      final ctx = tester.element(find.byType(SizedBox));
      unawaited(
        Navigator.of(ctx).push(
          PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => const ConnectionsPanel(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Remote Repositories'), findsOneWidget);
      expect(find.text('2 repos'), findsOneWidget);
      expect(find.text('alpha'), findsNothing, reason: 'collapsed by default');

      await tester.tap(find.text('Prod'));
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(recorder.connected, isEmpty,
          reason: 'expanding a host must not initiate a connection');

      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();
      expect(recorder.connected, [('c1', '/srv/beta')]);
      expect(find.byType(ConnectionsPanel), findsNothing,
          reason: 'connecting closes the panel');
    },
  );

  Future<void> pumpSwitcher(WidgetTester tester, ConnectionState state) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => _StubConnection(state)),
          savedConnectionsProvider.overrideWith((ref) async => const []),
          savedLocalReposProvider.overrideWith((ref) async => const []),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: ConnectionSwitcher(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('switcher button shows the server host for an SSH session', (
    tester,
  ) async {
    await pumpSwitcher(
      tester,
      const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.ssh,
        host: 'build01.example.com',
        connectionLabel: 'my-repo',
      ),
    );
    expect(find.text('build01.example.com'), findsOneWidget);
    // The repo/connection label is not shown on the button for SSH.
    expect(find.text('my-repo'), findsNothing);
  });

  testWidgets('switcher button shows "Local" for a local session, not the '
      'repo name', (tester) async {
    await pumpSwitcher(
      tester,
      const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        connectionLabel: 'my-local-repo',
      ),
    );
    expect(find.text('Local'), findsOneWidget);
    // The repo name is shown above the button (CurrentRepoIndicator), so
    // repeating it on the button would be redundant.
    expect(find.text('my-local-repo'), findsNothing);
  });

  testWidgets('Logout button disconnects (returns to the connection card)', (
    tester,
  ) async {
    final fake = _FakeConnectionController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectionProvider.overrideWith(() => fake)],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: LogoutButton(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Logout'), findsOneWidget);
    await tester.tap(find.text('Logout'));
    await tester.pump();
    expect(fake.disconnectCalled, isTrue);
  });
}
