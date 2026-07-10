// The landing page: two actions, a disabled recent pulldown when empty, an
// enabled one when profiles exist, and "Add SSH Remote" opening the form sheet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/connection/connection_landing.dart';

Future<void> _pump(
  WidgetTester tester, {
  List<SavedConnection> saved = const [],
  List<SavedLocalRepo> savedLocal = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedConnectionsProvider.overrideWith((ref) => saved),
        savedLocalReposProvider.overrideWith((ref) => savedLocal),
        // The clone sheet's default GitHub tab lists repos through the local
        // executor for a This-Mac destination — stub it so no real gh runs.
        forgeRepoListProvider.overrideWith((ref, key) async => []),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionLanding(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Stands in for the real controller so a test can force the `lost` phase
/// (normally only reached via a live drop + `stopReconnect()`) and observe
/// which action — `reconnect()` or `disconnect()` — a button actually invokes.
class _FakeConnectionController extends ConnectionController {
  final ConnectionState initial;
  bool reconnectCalled = false;
  bool disconnectCalled = false;
  _FakeConnectionController(this.initial);

  @override
  ConnectionState build() => initial;

  @override
  Future<void> reconnect() async {
    reconnectCalled = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
  }
}

void main() {
  testWidgets('shows both actions; recent pulldown disabled when empty', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Add SSH Remote'), findsOneWidget);
    expect(find.text('No Recent Workspaces'), findsOneWidget);
    expect(find.text('Recent Workspaces'), findsNothing);
  });

  testWidgets('recent connections enable the pulldown', (tester) async {
    await _pump(
      tester,
      saved: [
        SavedConnection(
          id: 'r',
          label: 'Prod box',
          host: 'h',
          port: 22,
          username: 'u',
          repoPath: '/r',
          lastConnectedAt: DateTime.utc(2026, 6, 1),
        ),
      ],
    );
    expect(find.text('Recent Workspaces'), findsOneWidget);
    expect(find.text('No Recent Workspaces'), findsNothing);
  });

  testWidgets('a saved local repo appears under Recent Workspaces', (
    tester,
  ) async {
    // The reported bug: only connections showed up. A saved local repo with no
    // saved connections must both enable the pulldown and appear in it.
    await _pump(
      tester,
      savedLocal: [
        SavedLocalRepo(
          id: 'lr',
          label: 'My Local Repo',
          repoPath: '/Users/me/proj',
          lastConnectedAt: DateTime.utc(2026, 6, 1),
        ),
      ],
    );
    expect(find.text('Recent Workspaces'), findsOneWidget);
    expect(find.text('No Recent Workspaces'), findsNothing);

    await tester.tap(find.text('Recent Workspaces'));
    await tester.pumpAndSettle();
    expect(find.text('My Local Repo'), findsOneWidget);
  });

  testWidgets('Recent Workspaces drops down and dismisses on outside tap', (
    tester,
  ) async {
    await _pump(
      tester,
      saved: [
        SavedConnection(
          id: 'r',
          label: 'Prod box',
          host: 'h',
          port: 22,
          username: 'u',
          repoPath: '/r',
          lastConnectedAt: DateTime.utc(2026, 6, 1),
        ),
      ],
    );

    // Not shown until the button is tapped.
    expect(find.text('Prod box'), findsNothing);
    await tester.tap(find.text('Recent Workspaces'));
    await tester.pumpAndSettle();
    expect(find.text('Prod box'), findsOneWidget);

    // A tap anywhere outside the menu closes it.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Prod box'), findsNothing);
  });

  testWidgets('Add SSH Remote opens the form in a sheet', (tester) async {
    await _pump(tester);
    // The form's fields are not present until the sheet is opened.
    expect(find.text('Repository path'), findsNothing);

    await tester.tap(find.text('Add SSH Remote'));
    await tester.pumpAndSettle();

    expect(find.text('Repository path'), findsOneWidget);
  });

  testWidgets('Add Local Repository opens the local-repo sheet', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Add Local Repository'), findsOneWidget);
    expect(find.text('Choose…'), findsNothing);

    await tester.tap(find.text('Add Local Repository'));
    await tester.pumpAndSettle();

    expect(find.text('Choose…'), findsOneWidget);
    expect(find.text('No folder chosen'), findsOneWidget);
  });

  testWidgets('Clone Repository opens the clone sheet in landing mode', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Clone Repository'));
    await tester.pumpAndSettle();

    expect(find.text('Clone repository'), findsOneWidget);
    // Landing wizard: 'Destination' appears as the step's section caption
    // and in the breadcrumb indicator.
    expect(find.text('Destination'), findsWidgets, reason: 'landing mode');
    expect(find.text('This Mac'), findsOneWidget);
  });

  testWidgets('Create Repository opens the create sheet in landing mode', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Create Repository'));
    await tester.pumpAndSettle();

    expect(find.text('Create repository'), findsOneWidget);
    // Landing mode: the wizard opens on its Destination step (the title also
    // appears in the step-indicator breadcrumb).
    expect(find.text('Destination'), findsWidgets, reason: 'landing mode');
    expect(find.text('This Mac'), findsWidgets);
  });

  testWidgets(
    'a lost connection offers Reconnect and Start Fresh, wired to the '
    'right controller methods',
    (tester) async {
      final fake = _FakeConnectionController(
        const ConnectionState(phase: ConnectionPhase.lost, host: 'h'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [connectionProvider.overrideWith(() => fake)],
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: ConnectionLanding(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.textContaining('h'), findsWidgets);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('Start Fresh'), findsOneWidget);

      await tester.tap(find.text('Reconnect'));
      await tester.pump();
      expect(fake.reconnectCalled, isTrue);
      expect(fake.disconnectCalled, isFalse);

      await tester.tap(find.text('Start Fresh'));
      await tester.pump();
      expect(fake.disconnectCalled, isTrue);
    },
  );
}
