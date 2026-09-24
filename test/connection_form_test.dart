// Smoke coverage for the "new SSH connection" sheet. It is the only way into
// a remote session and, until now, nothing pumped it: a missing provider
// override or a null-deref here would only have surfaced on the Mac.
//
// One build path (the fields and both exits) plus the validation path, which
// is the branch that keeps a half-filled form from starting a connect.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/connection/connection_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const {});
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionForm(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Connects only to the paths in [works], expanding `~/` to `/home/u` as the
/// real connect does, and stamps the saved profile the way a real successful
/// connect does (lastConnectedAt).
class _ScriptedConnect extends ConnectionController {
  _ScriptedConnect(this.store, this.works);
  final ConnectionStore store;
  final Set<String> works;

  /// Every repository path connect() was asked for, in order.
  final attempts = <String>[];

  @override
  ConnectionState build() => const ConnectionState();

  @override
  Future<void> connect({
    required SSHConnectionProfile profile,
    required String repoPath,
    String? gitlabToken,
    String? githubToken,
    String? connectionId,
    String? connectionLabel,
    List<String>? repoPaths,
    List<String> fsmonitorPaths = const [],
    Map<String, String> scopedGitDirs = const {},
    bool reconnecting = false,
  }) async {
    attempts.add(repoPath);
    final resolved = repoPath.startsWith('~/')
        ? '/home/u${repoPath.substring(1)}'
        : repoPath;
    if (!works.contains(resolved)) {
      state = ConnectionState(
        phase: ConnectionPhase.error,
        error: 'not a git repository: $resolved',
      );
      return;
    }
    if (connectionId != null) await store.touch(connectionId);
    state = ConnectionState(
      phase: ConnectionPhase.connected,
      repoPath: resolved,
      repoPaths: [resolved],
      connectionId: connectionId,
    );
  }
}

/// Secrets in memory: without this the store falls back to a credentials
/// file, and real file I/O never completes inside a widget test.
void _mockSecureStorage(WidgetTester tester) {
  final vault = <String, String>{};
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>();
      final key = args?['key'] as String?;
      switch (call.method) {
        case 'read':
          return vault[key];
        case 'write':
          vault[key!] = args!['value'] as String;
          return null;
        case 'delete':
          vault.remove(key);
          return null;
        case 'containsKey':
          return vault.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(vault);
        case 'deleteAll':
          vault.clear();
          return null;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    ),
  );
}

/// Pumps until [done], giving real time between pumps: ConnectionStore
/// consults its credentials file on every secret read and write, and real
/// file I/O only completes outside a widget test's fake-async zone.
Future<void> _settleIo(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Finder _repoField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == '/srv/git/my-project',
);

Future<(ConnectionStore, ProviderContainer)> _pumpSaving(
  WidgetTester tester, {
  required Set<String> works,
  SavedConnection? existing,
}) async {
  // Seeded straight into preferences, as connection_edit_test does: the
  // store's write queue belongs to the zone it was built in, so a seed run
  // through it under runAsync deadlocks against the fake-async zone.
  SharedPreferences.setMockInitialValues({
    if (existing != null)
      'saved_connections': jsonEncode([
        // It has connected before.
        existing.copyWith(lastConnectedAt: DateTime(2026)).toJson(),
      ]),
  });
  _mockSecureStorage(tester);
  final tmp = Directory.systemTemp.createTempSync('mg_form_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final store = ConnectionStore(dotfilePath: '${tmp.path}/credentials.json');
  final container = ProviderContainer(
    overrides: [
      connectionStoreProvider.overrideWithValue(store),
      connectionProvider.overrideWith(() => _ScriptedConnect(store, works)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(savedConnectionsProvider.future);
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionForm(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(MacosTextField).at(0), 'box');
  await tester.enterText(find.byType(MacosTextField).at(2), 'u');
  await tester.enterText(find.byType(MacosTextField).at(3), 'pw');
  return (store, container);
}

Future<void> _submit(
  WidgetTester tester,
  ProviderContainer container,
  String repoPath,
) async {
  await container.read(savedConnectionsProvider.future);
  await tester.enterText(_repoField(), repoPath);
  final connect =
      container.read(connectionProvider.notifier) as _ScriptedConnect;
  final before = connect.attempts.length;
  await tester.pump(); // rebuild Connect as enabled before tapping it
  await tester.tap(find.text('Connect'));
  // Everything after connect() touches preferences only, which the
  // closing pumpAndSettle drains.
  await _settleIo(tester, () => connect.attempts.length > before);
  // The submit reached connect(): a Connect that never fires would leave
  // the saved list untouched and pass the 'adds nothing' case vacuously.
  expect(connect.attempts.length, before + 1);
  expect(connect.attempts.last, repoPath);
}

/// The one connection in preferences, read as the store writes it.
Future<SavedConnection> _saved() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = jsonDecode(prefs.getString('saved_connections')!) as List;
  return SavedConnection.fromJson(raw.single as Map<String, dynamic>);
}

void main() {
  testWidgets('renders the SSH fields and the Connect action', (tester) async {
    await _pump(tester);

    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.textContaining('Private key'), findsWidgets);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Port defaults to 22', (tester) async {
    await _pump(tester);

    // A blank port would silently become 22 anyway (int.tryParse ?? 22), but
    // the user must see what they are about to connect to.
    expect(find.text('22'), findsWidgets);
  });

  testWidgets('Connect with an empty host does not start a connection', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // Still on the form — a validation failure must not dismiss it, and must
    // not throw.
    expect(find.byType(ConnectionForm), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a filled host and username clear the required-field guard', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(
      find.byType(MacosTextField).at(0),
      'gitlab.example.com',
    );
    await tester.enterText(find.byType(MacosTextField).at(2), 'deploy');
    await tester.pumpAndSettle();

    expect(find.text('Host is required'), findsNothing);
    expect(find.text('Username is required'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('what Save connection keeps', () {
    const known = SavedConnection(
      id: 'c1',
      label: '',
      host: 'box',
      port: 22,
      username: 'u',
      repoPath: '/srv/a',
      repoPaths: ['/srv/a'],
    );

    testWidgets('a failed connect adds no path to a known connection', (
      tester,
    ) async {
      final (store, container) = await _pumpSaving(
        tester,
        works: {'/srv/a'},
        existing: known,
      );
      await _submit(tester, container, '/srv/typo');

      final saved = await _saved();
      expect(saved.allRepoPaths, ['/srv/a']);
      expect(saved.repoPath, '/srv/a');
    });

    testWidgets('a path that connects is added, as the default', (
      tester,
    ) async {
      final (store, container) = await _pumpSaving(
        tester,
        works: {'/srv/a', '/srv/b'},
        existing: known,
      );
      await _submit(tester, container, '/srv/b');

      final saved = await _saved();
      expect(saved.repoPath, '/srv/b');
      expect(saved.allRepoPaths, ['/srv/b', '/srv/a']);
    });

    testWidgets('a profile that never connected is replaced, not merged — '
        'the reported bug', (tester) async {
      // First attempt: a path that cannot work. Second: the right one. The
      // first must not survive as one of the connection's repositories.
      final (store, container) = await _pumpSaving(
        tester,
        works: {'/srv/good'},
      );
      await _submit(tester, container, '~/gitrepos/app');
      expect((await _saved()).allRepoPaths, ['~/gitrepos/app']);

      await _submit(tester, container, '/srv/good');

      expect((await _saved()).allRepoPaths, ['/srv/good']);
    });

    testWidgets('a ~ path is saved as the connection resolved it', (
      tester,
    ) async {
      final (store, container) = await _pumpSaving(
        tester,
        works: {'/home/u/src/app'},
      );
      await _submit(tester, container, '~/src/app');

      final saved = await _saved();
      expect(saved.repoPath, '/home/u/src/app');
      expect(saved.allRepoPaths, ['/home/u/src/app']);
    });
  });
}
