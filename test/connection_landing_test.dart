// The landing page: two actions — Connections Manager (the single entry
// point to every workspace action) and the Recent Repositories pulldown
// (disabled when empty, enabled when saved repos exist). The pulldown is
// repo-centric: it lists specific repos (a multi-repo connection expands into
// one row per repo) so a click opens that repo directly.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/connection/connection_landing.dart';

Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

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
        // executor for a This-Mac destination — stub it (and the auth-host
        // prefill probe) so no real gh runs.
        forgeRepoListProvider.overrideWith((ref, key) async => []),
        forgeAuthHostProvider.overrideWith((ref, key) async => null),
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
    expect(find.text('Connections Manager'), findsOneWidget);
    expect(find.text('No Recent Repositories'), findsOneWidget);
    expect(find.text('Recent Repositories'), findsNothing);
    // The per-task buttons moved into the Connections Manager — the landing
    // itself stays a single clear entry point.
    expect(find.text('Add SSH Remote'), findsNothing);
    expect(find.text('Add Local Repository'), findsNothing);
    expect(find.text('Clone Repository'), findsNothing);
    expect(find.text('Create Repository'), findsNothing);
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
    expect(find.text('Recent Repositories'), findsOneWidget);
    expect(find.text('No Recent Repositories'), findsNothing);
  });

  testWidgets('a saved local repo appears under Recent Repositories', (
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
    expect(find.text('Recent Repositories'), findsOneWidget);
    expect(find.text('No Recent Repositories'), findsNothing);

    await tester.tap(find.text('Recent Repositories'));
    await tester.pumpAndSettle();
    expect(find.text('My Local Repo'), findsOneWidget);
  });

  testWidgets('Recent Repositories drops down and dismisses on outside tap', (
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

    // Not shown until the button is tapped. 'Prod box' is the connection name,
    // now shown as the repo row's location subtitle (repo basename 'r' is the
    // title).
    expect(find.text('Prod box'), findsNothing);
    await tester.tap(find.text('Recent Repositories'));
    await tester.pumpAndSettle();
    expect(find.text('Prod box'), findsOneWidget);
    expect(find.text('r'), findsOneWidget);

    // A tap anywhere outside the menu closes it.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Prod box'), findsNothing);
  });

  testWidgets(
    'Connections Manager opens the connections panel with its full toolbar',
    (tester) async {
      await _pump(tester);
      expect(find.text('Connections'), findsNothing);

      await tester.tap(find.text('Connections Manager'));
      await tester.pumpAndSettle();

      // The panel is open with every workspace action available from its
      // toolbar (each action's own sheet is covered by the switcher tests).
      expect(find.text('Connections'), findsOneWidget);
      expect(_byMacosTooltip('Add connection'), findsOneWidget);
      expect(_byMacosTooltip('Add existing repository'), findsOneWidget);
      expect(_byMacosTooltip('Clone repository'), findsOneWidget);
      expect(_byMacosTooltip('Create repository'), findsOneWidget);
    },
  );

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
