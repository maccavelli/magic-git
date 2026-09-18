// The Connections panel's "Local Repositories" section: a header + a tile
// per saved local repo, and the "Add existing repository" toolbar button
// opening the unified add-existing sheet (Local by default, with a Location
// dropdown listing every saved SSH connection).

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/switcher/connection_switcher.dart';
import 'package:remote_magic_git/features/tabs/saved_workspaces_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ToolIconButton wraps MacosTooltip (not Flutter's standard Tooltip), so
// find.byTooltip doesn't match it — match on the tooltip message directly.
Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

/// Records whether `disconnect()` — the Logout button's action — was invoked.
class _FakeConnectionController extends ConnectionController {
  _FakeConnectionController([this.initialState = const ConnectionState()]);
  final ConnectionState initialState;
  bool disconnectCalled = false;
  @override
  ConnectionState build() => initialState;
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

/// The [MacosIcon] with [icon] in the row whose title is [title]: the nearest
/// `Row` above the title text, so a glyph elsewhere on screen cannot satisfy it.
Finder _rowIcon(String title, IconData icon) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
  matching: find.byWidgetPredicate((w) => w is MacosIcon && w.icon == icon),
);

Future<void> _pump(
  WidgetTester tester, {
  List<SavedLocalRepo> savedLocal = const [],
  List<SavedConnection> saved = const [],
  ConnectionState? connection,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (connection != null)
          connectionProvider.overrideWith(() => _StubConnection(connection)),
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
  testWidgets('shows the empty state with all start options', (tester) async {
    await _pump(tester);
    expect(find.text('No saved connections'), findsOneWidget);
    expect(find.text('Add local repository'), findsOneWidget);
    expect(find.text('New SSH connection'), findsOneWidget);
    expect(find.text('Clone repository'), findsOneWidget);
    expect(find.text('Create repository'), findsOneWidget);
    expect(find.text('Local Repositories'), findsNothing);
  });

  testWidgets('Saved workspaces opens the management sheet', (tester) async {
    await _pump(tester);

    await tester.tap(_byMacosTooltip('Saved workspaces'));
    await tester.pumpAndSettle();

    expect(find.byType(SavedWorkspacesSheet), findsOneWidget);
    expect(find.text('No saved workspaces yet.'), findsOneWidget);
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

  testWidgets('Add existing repository opens the unified add sheet, defaulting '
      'to a local folder pick', (tester) async {
    await _pump(
      tester,
      saved: const [
        SavedConnection(
          id: 'c1',
          label: 'Prod',
          host: 'h',
          port: 22,
          username: 'u',
          repoPath: '/srv/alpha',
          repoPaths: ['/srv/alpha'],
        ),
      ],
    );
    // Assert on the sheet's unique folder-picker row rather than its title,
    // which is a separate concern from the toolbar tooltip we tap.
    expect(find.text('Choose…'), findsNothing);

    await tester.tap(_byMacosTooltip('Add existing repository'));
    await tester.pumpAndSettle();

    // The sheet opens in Local mode: its local folder-picker button is present
    // and the Location dropdown shows the default selection.
    expect(find.text('Add Existing Repository'), findsOneWidget);
    expect(find.text('Choose…'), findsOneWidget);
    expect(find.text('Local (this Mac)'), findsOneWidget);
    // The scoped work-tree (dotfiles) toggle is on the card.
    expect(find.text('Scoped work-tree repo (dotfiles)'), findsOneWidget);

    // Opening the Location dropdown lists Local plus every saved SSH connection.
    await tester.tap(find.text('Local (this Mac)'));
    await tester.pumpAndSettle();
    expect(find.text('Prod'), findsWidgets);
  });

  testWidgets('Add connection opens the SSH connection form sheet', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Add SSH Remote'), findsNothing);

    await tester.tap(_byMacosTooltip('Add connection'));
    await tester.pumpAndSettle();

    // The full SSH form is up, with Connect disabled until the required
    // fields (host, username, repo path, an auth method) are filled in.
    expect(find.text('Add SSH Remote'), findsOneWidget);
    // AppPushButton subclasses PushButton, so byType(PushButton) won't match
    // it — find by the subclass.
    final connect = tester.widget<AppPushButton>(
      find.widgetWithText(AppPushButton, 'Connect'),
    );
    expect(connect.onPressed, isNull);
    // 0009 L18: a dimmed Connect names the first missing field, and Enter
    // on a single-line field is wired to submit.
    expect(find.text('Host is required'), findsOneWidget);
    expect(
      tester
          .widget<MacosTextField>(find.byType(MacosTextField).first)
          .onSubmitted,
      isNotNull,
    );
  });

  testWidgets('connection form caption walks to the next invalid field', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_byMacosTooltip('Add connection'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(MacosTextField).first,
      'gitlab.example.com',
    );
    await tester.pump();
    expect(find.text('Host is required'), findsNothing);
    expect(find.text('Username is required'), findsOneWidget);
  });

  testWidgets('the empty state\'s New-connection button opens the same form', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('New SSH connection'));
    await tester.pumpAndSettle();
    expect(find.text('Add SSH Remote'), findsOneWidget);
  });

  testWidgets('Clone repository opens the clone sheet (landing mode while '
      'disconnected)', (tester) async {
    await _pump(tester);
    await tester.tap(_byMacosTooltip('Clone repository'));
    await tester.pumpAndSettle();

    expect(find.text('Clone repository'), findsOneWidget);
    // Landing wizard: 'Target' appears as the step's section caption
    // and in the breadcrumb indicator.
    expect(find.text('Target'), findsWidgets);
  });

  testWidgets('Create repository opens the create sheet', (tester) async {
    await _pump(tester);
    await tester.tap(_byMacosTooltip('Create repository'));
    await tester.pumpAndSettle();

    expect(find.text('Create repository'), findsOneWidget);
    // Disconnected → landing variant: the wizard opens on Destination.
    expect(find.text('Target'), findsWidgets);
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
      expect(
        recorder.connected,
        isEmpty,
        reason: 'expanding a host must not initiate a connection',
      );

      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();
      expect(recorder.connected, [('c1', '/srv/beta')]);
      expect(
        find.byType(ConnectionsPanel),
        findsNothing,
        reason: 'connecting closes the panel',
      );
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

  // MADR 0052: the button's label names what it opens. Where the session is
  // lives in the sidebar info card's Location row now, not on the button.
  const sshSession = ConnectionState(
    phase: ConnectionPhase.connected,
    backend: ConnectionBackend.ssh,
    host: 'build01.example.com',
    connectionLabel: 'my-repo',
  );

  testWidgets('B1 switcher button reads Connections for an SSH session', (
    tester,
  ) async {
    await pumpSwitcher(tester, sshSession);
    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('build01.example.com'), findsNothing);
    expect(find.text('my-repo'), findsNothing);
  });

  testWidgets('B2 switcher button reads Connections for a local session', (
    tester,
  ) async {
    await pumpSwitcher(
      tester,
      const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        connectionLabel: 'my-local-repo',
      ),
    );
    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Local'), findsNothing);
    expect(find.text('This Mac'), findsNothing);
    expect(find.text('my-local-repo'), findsNothing);
  });

  testWidgets('B3 tapping the switcher opens the connections manager', (
    tester,
  ) async {
    await pumpSwitcher(tester, sshSession);
    await tester.tap(find.byType(ConnectionSwitcher));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionsPanel), findsOneWidget);
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

  testWidgets('deleting active sole local repo disconnects and pops sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fake = _FakeConnectionController(
      const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        connectionId: 'l1',
        repoPath: '/path',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedLocalReposProvider.overrideWith(
            (ref) async => const [
              SavedLocalRepo(id: 'l1', label: 'Sole Repo', repoPath: '/path'),
            ],
          ),
          savedConnectionsProvider.overrideWith((ref) async => const []),
          connectionProvider.overrideWith(() => fake),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: ConnectionsPanel(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sole Repo'), findsOneWidget);
    // Find trash button for local repo tile
    final trash = _byMacosTooltip('Remove repository');
    expect(trash, findsOneWidget);
    await tester.tap(trash);
    await tester.pumpAndSettle();

    // Confirm dialog appears
    expect(find.text('Remove local repository'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(fake.disconnectCalled, isTrue);
  });

  // MADR 0052 amendment 0052.2: the manager's connection and local rows show
  // the location glyph — a globe for a remote host, a folder for a local repo,
  // active or not — the same as the tab, status bar and Location row.
  testWidgets('M1 saved rows: the SSH connection shows the globe, the local '
      'repo the folder, even while active', (tester) async {
    await _pump(
      tester,
      saved: const [
        SavedConnection(
          id: 'c1',
          label: 'Build box',
          host: 'build01.example.com',
          port: 22,
          username: 'deploy',
          repoPath: '/srv/app',
        ),
      ],
      savedLocal: const [
        SavedLocalRepo(id: 'lr', label: 'My Local Repo', repoPath: '/me/proj'),
      ],
      connection: const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        connectionId: 'lr',
        repoPath: '/me/proj',
        repoPaths: ['/me/proj'],
      ),
    );

    expect(_rowIcon('Build box', CupertinoIcons.globe), findsOneWidget);
    expect(_rowIcon('My Local Repo', CupertinoIcons.folder), findsOneWidget);
    expect(
      _rowIcon('My Local Repo', CupertinoIcons.folder_fill),
      findsNothing,
      reason: 'the active local row shows the location glyph, not a fill',
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.desktopcomputer,
      ),
      findsNothing,
    );
  });

  testWidgets('M2 an unsaved SSH session shows the globe', (tester) async {
    await _pump(
      tester,
      connection: const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.ssh,
        host: 'adhoc.example.com',
        connectionLabel: 'adhoc.example.com',
        repoPath: '/srv/app',
        repoPaths: ['/srv/app'],
      ),
    );

    expect(
      _rowIcon('adhoc.example.com (unsaved)', CupertinoIcons.globe),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.desktopcomputer,
      ),
      findsNothing,
    );
  });

  testWidgets('M3 an unsaved local session shows the folder', (tester) async {
    await _pump(
      tester,
      connection: const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        repoPath: '/me/proj',
        repoPaths: ['/me/proj'],
      ),
    );

    expect(_rowIcon('proj (unsaved)', CupertinoIcons.folder), findsOneWidget);
    expect(
      _rowIcon('proj (unsaved)', CupertinoIcons.folder_fill),
      findsNothing,
    );
  });
}
