// The Connections panel's edit flows: the pencil on a connection row opens a
// card with every profile field editable (blank secrets meaning "keep"), the
// pencil on a remote repo row edits that entry's label, path, and fsmonitor
// (all travelling together across a repoint), and the pencil on a local repo
// tile renames its label. Also covers the friendly-name label surfacing on
// remote repo tiles and the Add-repository card.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/switcher/connection_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ToolIconButton wraps MacosTooltip (not Flutter's standard Tooltip), so
// find.byTooltip doesn't match it — match on the tooltip message directly.
Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

const _conn = SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'build01.example.com',
  port: 22,
  username: 'deploy',
  repoPath: '/srv/alpha',
  repoPaths: ['/srv/alpha', '/srv/beta'],
  fsmonitorPaths: ['/srv/beta'],
);

// Same host, but beta carries a friendly label (and fsmonitor).
const _connLabeled = SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'build01.example.com',
  port: 22,
  username: 'deploy',
  repoPath: '/srv/alpha',
  repoPaths: ['/srv/alpha', '/srv/beta'],
  fsmonitorPaths: ['/srv/beta'],
  repoLabels: {'/srv/beta': 'Beta Service'},
);

const _localRepo = SavedLocalRepo(
  id: 'l1',
  label: 'My Project',
  repoPath: '/Users/me/code/proj',
);

/// In-memory stand-in for the Keychain, pre-seeded with [secrets]: without it
/// every secret call throws MissingPluginException and the store falls back
/// to its dotfile — real dart:io futures that the fake-async `pumpAndSettle`
/// can never drain, so the save would still be in flight when the test
/// asserts. (A read that returns null falls through to the dotfile too, which
/// is why the seed matters: the edited connection's secrets must resolve from
/// the vault alone.)
Map<String, String> _mockSecureStorage(
  WidgetTester tester, {
  Map<String, String> secrets = const {},
}) {
  final vault = <String, String>{...secrets};
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
  return vault;
}

/// Every secret slot ConnectionStore keeps for connection [id] — the vault
/// seed that lets each `…For(id)` read resolve without touching the dotfile.
Map<String, String> _seededSecrets(String id) => {
  'conn_secret_$id': 'hunter2',
  'conn_key_$id': 'PEM-DATA',
  'conn_pass_$id': 'key-pass',
  'conn_gltoken_$id': 'glpat-x',
  'conn_ghtoken_$id': 'ghp-x',
};

Future<List<SavedConnection>> _storedConnections() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('saved_connections')!;
  return [
    for (final item in jsonDecode(raw) as List)
      SavedConnection.fromJson(item as Map<String, dynamic>),
  ];
}

Future<List<SavedLocalRepo>> _storedLocalRepos() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('saved_local_repos')!;
  return [
    for (final item in jsonDecode(raw) as List)
      SavedLocalRepo.fromJson(item as Map<String, dynamic>),
  ];
}

Future<Map<String, String>> _pump(
  WidgetTester tester, {
  List<SavedConnection> saved = const [],
  List<SavedLocalRepo> savedLocal = const [],
  Map<String, String> secrets = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    if (saved.isNotEmpty)
      'saved_connections': jsonEncode([for (final c in saved) c.toJson()]),
    if (savedLocal.isNotEmpty)
      'saved_local_repos': jsonEncode([for (final r in savedLocal) r.toJson()]),
  });
  final vault = _mockSecureStorage(tester, secrets: secrets);
  // Belt to the mock's braces: if a secret call ever did fall through to the
  // dotfile, land it in a temp file rather than the real
  // ~/.config/magic_git/credentials.json.
  final tmp = Directory.systemTemp.createTempSync('magic_git_edit_test');
  addTearDown(() => tmp.deleteSync(recursive: true));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionStoreProvider.overrideWithValue(
          ConnectionStore(dotfilePath: '${tmp.path}/credentials.json'),
        ),
        savedConnectionsProvider.overrideWith((ref) async => saved),
        savedLocalReposProvider.overrideWith((ref) async => savedLocal),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionsPanel(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return vault;
}

void main() {
  testWidgets('the connection pencil opens a card prefilled with the profile '
      'and saves edited metadata', (tester) async {
    final vault = await _pump(
      tester,
      saved: const [_conn],
      secrets: _seededSecrets('c1'),
    );

    await tester.tap(_byMacosTooltip('Edit connection'));
    await tester.pumpAndSettle();

    // All metadata fields arrive prefilled and editable.
    expect(find.text('Edit connection'), findsOneWidget);
    expect(find.widgetWithText(MacosTextField, 'Prod'), findsOneWidget);
    expect(
      find.widgetWithText(MacosTextField, 'build01.example.com'),
      findsOneWidget,
    );
    expect(find.widgetWithText(MacosTextField, 'deploy'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(MacosTextField, 'Prod'),
      'Production',
    );
    await tester.pump();
    expect(
      find.widgetWithText(MacosTextField, 'Production'),
      findsOneWidget,
      reason: 'the label edit landed in the field',
    );
    await tester.enterText(
      find.widgetWithText(MacosTextField, 'deploy'),
      'ops',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('Edit connection'),
      findsNothing,
      reason: 'Save closes the card',
    );

    final stored = (await _storedConnections()).single;
    expect(stored.label, 'Production');
    expect(stored.username, 'ops');
    // Untouched fields (and the repo list) survive the round trip.
    expect(stored.host, 'build01.example.com');
    expect(stored.id, 'c1');
    expect(stored.allRepoPaths, ['/srv/alpha', '/srv/beta']);
    expect(stored.fsmonitorPaths, ['/srv/beta']);
    // Secrets left blank in the card are kept, not cleared.
    expect(vault['conn_secret_c1'], 'hunter2');
    expect(vault['conn_key_c1'], 'PEM-DATA');
  });

  testWidgets('an invalid port disables Save', (tester) async {
    await _pump(tester, saved: const [_conn]);
    await tester.tap(_byMacosTooltip('Edit connection'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(MacosTextField, '22'), '99999');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The sheet is still up (Save was inert) and nothing was persisted.
    expect(find.text('Edit connection'), findsOneWidget);
    expect((await _storedConnections()).single.port, 22);
  });

  testWidgets('the repo-row pencil repoints the entry, migrating its '
      'label and fsmonitor preference', (tester) async {
    await _pump(tester, saved: const [_connLabeled]);

    // Expand the host to reveal its repository rows.
    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();

    // Edit the second repo (beta — labelled, fsmonitor on).
    await tester.tap(_byMacosTooltip('Edit repository').last);
    await tester.pumpAndSettle();
    expect(find.text('Edit repository'), findsWidgets);
    // The label field arrives prefilled with beta's friendly name.
    expect(find.widgetWithText(MacosTextField, 'Beta Service'), findsOneWidget);

    // Repoint the path (targeting the field prefilled with the old path).
    await tester.enterText(
      find.widgetWithText(MacosTextField, '/srv/beta'),
      '/srv/gamma',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = (await _storedConnections()).single;
    expect(stored.allRepoPaths, ['/srv/alpha', '/srv/gamma']);
    expect(stored.repoPath, '/srv/alpha', reason: 'default repo unchanged');
    expect(
      stored.fsmonitorPaths,
      ['/srv/gamma'],
      reason: 'the fsmonitor preference follows the renamed entry',
    );
    expect(stored.repoLabels, {
      '/srv/gamma': 'Beta Service',
    }, reason: 'the friendly label follows the renamed entry');
  });

  testWidgets('the repo-row pencil sets a friendly label without moving the '
      'path', (tester) async {
    await _pump(tester, saved: const [_conn]);
    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();

    // Edit the first repo (alpha — no label yet). Its label field is empty and
    // shows the basename as its placeholder.
    await tester.tap(_byMacosTooltip('Edit repository').first);
    await tester.pumpAndSettle();
    // The Label field is the one prefilled empty; enter a name into it.
    await tester.enterText(
      find.widgetWithText(MacosTextField, 'alpha'),
      'The Alpha',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = (await _storedConnections()).single;
    expect(stored.repoLabels, {'/srv/alpha': 'The Alpha'});
    expect(stored.allRepoPaths, [
      '/srv/alpha',
      '/srv/beta',
    ], reason: 'paths untouched');
    expect(stored.fsmonitorPaths, ['/srv/beta'], reason: 'fsmonitor untouched');
  });

  testWidgets('a remote repo tile shows its friendly label over the basename', (
    tester,
  ) async {
    await _pump(tester, saved: const [_connLabeled]);
    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();

    // Beta carries a label → shown; alpha has none → basename.
    expect(find.text('Beta Service'), findsOneWidget);
    expect(find.text('beta'), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
  });

  testWidgets('a non-absolute path leaves Save inert', (tester) async {
    await _pump(tester, saved: const [_conn]);
    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();
    await tester.tap(_byMacosTooltip('Edit repository').first);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(MacosTextField, '/srv/alpha'),
      'srv/alpha',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('Edit repository'),
      findsWidgets,
      reason: 'Save stays inert while the path is not absolute',
    );
    // Nothing persisted.
    expect((await _storedConnections()).single.repoPath, '/srv/alpha');
  });

  // Registering an existing repo onto a saved connection moved out of the
  // per-connection "Add repository" row (removed) into the unified
  // AddExistingRepoSheet, whose remote branch dials the host and finalizes over
  // SSH — exercised at the provisioning layer, not as a plain widget test.

  testWidgets('the local repo pencil renames the label (folder read-only)', (
    tester,
  ) async {
    await _pump(tester, savedLocal: const [_localRepo]);

    await tester.tap(_byMacosTooltip('Edit repository'));
    await tester.pumpAndSettle();

    expect(find.text('Edit repository'), findsOneWidget);
    // The folder is displayed but not editable — no text field carries it.
    expect(find.text('/Users/me/code/proj'), findsOneWidget);
    expect(
      find.widgetWithText(MacosTextField, '/Users/me/code/proj'),
      findsNothing,
    );

    await tester.enterText(
      find.widgetWithText(MacosTextField, 'My Project'),
      'Renamed Project',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = (await _storedLocalRepos()).single;
    expect(stored.label, 'Renamed Project');
    expect(stored.repoPath, '/Users/me/code/proj');
    expect(stored.id, 'l1');
  });

  testWidgets('the local edit card can toggle fsmonitor too', (tester) async {
    await _pump(tester, savedLocal: const [_localRepo]);

    await tester.tap(_byMacosTooltip('Edit repository'));
    await tester.pumpAndSettle();
    // `.last`: the tile behind the sheet carries the same tooltip.
    await tester.tap(
      _byMacosTooltip('Git fsmonitor off (click to enable)').last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await _storedLocalRepos()).single.fsmonitorEnabled, isTrue);
  });
}
