// The Add Existing Repository sheet's scoped-repo behaviors:
//  * scoped-toggle ↔ fsmonitor interlock: git's fsmonitor daemon is never
//    valid on a scoped work-tree repo (it would index the entire work tree —
//    all of $HOME for a dotfiles repo — and git refuses it on a bare git-dir
//    anyway), so flipping the scoped toggle on must force the fsmonitor
//    toggle off AND disable it until scoped is off again.
//  * manual-toggle prefill: flipping the scoped toggle on by hand (which
//    permanently stops auto-detect from touching the toggle) still probes the
//    picked folder and pre-fills the empty git-dir field — the user should
//    never have to type a path detection can find.
//
// (The folder-pick auto-detection that flips the toggle automatically is
// exercised against real git in scoped_repo_autodetect_test.dart — the native
// picker doesn't run under `flutter test`.)
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/local_repo_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/connection/local_repo_form.dart';
import 'package:remote_magic_git/features/workspace/workspace_targets.dart';

import 'helpers/create_repo_harness.dart'
    show
        CountingScopedAccess,
        RecordingTabs,
        StubConnection,
        connectedState,
        installTabs,
        testConn;

/// The MacosSwitch sitting in the same Row as the label [text] — the switches
/// carry no semantics of their own, so the row label is the stable handle.
Finder _openButton() => find.widgetWithText(AppPushButton, 'Open');

Finder _switchNear(String text) => find.descendant(
  of: find.ancestor(of: find.textContaining(text), matching: find.byType(Row)),
  matching: find.byType(MacosSwitch),
);

Future<void> _pump(
  WidgetTester tester, {
  String? initialPickedPath,
  List<SavedConnection> connections = const [],
  List<SavedLocalRepo> localRepos = const [],
  LocalRepoStore? localStore,
  StubConnection? connection,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedConnectionsProvider.overrideWith((ref) async => connections),
        savedLocalReposProvider.overrideWith((ref) async => localRepos),
        if (localStore != null)
          localRepoStoreProvider.overrideWithValue(localStore),
        if (connection != null)
          connectionProvider.overrideWith(() => connection),
      ],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: AddExistingRepoSheet(initialPickedPath: initialPickedPath),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Records what the sheet persists, so a duplicate save is visible.
class _RecordingLocalStore extends LocalRepoStore {
  final List<SavedLocalRepo> saved = [];

  @override
  Future<void> save(SavedLocalRepo repo) async => saved.add(repo);
}

void main() {
  // MADR 0038 F5 — opening one folder twice must not produce two of
  // everything. `LocalRepoStore.save` de-duplicates by id alone, and this
  // sheet minted a fresh id every time, so the same path became two saved
  // records, two recents slots and two tabs.
  testWidgets('re-opening a saved folder reuses its record, not a new one', (
    tester,
  ) async {
    // `_persistLocal` mints a security-scoped bookmark before it saves, and an
    // unhandled method channel throws MissingPluginException — the save would
    // never be reached and the assertion would pass for the wrong reason.
    const bookmarks = MethodChannel('magicgit/bookmarks');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      bookmarks,
      (call) async => 'Ym0=',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        bookmarks,
        null,
      ),
    );
    final store = _RecordingLocalStore();
    const already = SavedLocalRepo(
      id: 'already-saved',
      label: 'App',
      repoPath: '/Users/me/app',
      bookmarkData: 'bm',
    );
    await _pump(
      tester,
      initialPickedPath: '/Users/me/app',
      localRepos: const [already],
      localStore: store,
      // Without a session the in-place open reports "not connected" and never
      // reaches the save at all — the assertion would pass on an empty store
      // for the wrong reason.
      connection: StubConnection(
        const ConnectionState(
          phase: ConnectionPhase.connected,
          backend: ConnectionBackend.local,
          repoPath: '/Users/me/app',
        ),
      ),
    );

    await tester.tap(find.widgetWithText(AppPushButton, 'Open'));
    await tester.pumpAndSettle();

    expect(store.saved, hasLength(1));
    expect(
      store.saved.single.id,
      'already-saved',
      reason: 'the same folder keeps one identity, as SSH profiles do',
    );
  });

  // MADR 0038 F5 follow-on — `openLocalRepoInTab` returned a bare null for two
  // different things, so the sheet reported the louder one. Focusing a tab that
  // is already on this repository is a success, not "too many tabs".
  testWidgets('re-opening a repo already in a tab focuses it, not the cap', (
    tester,
  ) async {
    const bookmarks = MethodChannel('magicgit/bookmarks');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      bookmarks,
      (call) async => 'Ym0=',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        bookmarks,
        null,
      ),
    );
    const already = SavedLocalRepo(
      id: 'already-saved',
      label: 'App',
      repoPath: '/Users/me/app',
      bookmarkData: 'bm',
    );
    final tabs = RecordingTabs();
    installTabs(tabs);
    // A tab already on this repo, under the id the sheet will now reuse...
    final existing = tabs.newTab()
      ..connectionId = 'already-saved'
      ..repoPath = '/Users/me/app';
    // ...and another one active, so "it focused the right tab" is observable.
    final other = tabs.newTab()
      ..connectionId = 'other'
      ..repoPath = '/srv/other';
    tabs.activate(other.id);

    await _pump(
      tester,
      initialPickedPath: '/Users/me/app',
      localRepos: const [already],
      localStore: _RecordingLocalStore(),
      connection: StubConnection(
        const ConnectionState(
          phase: ConnectionPhase.connected,
          backend: ConnectionBackend.local,
          repoPath: '/Users/me/app',
        ),
      ),
    );

    await tester.tap(_openButton());
    await tester.pumpAndSettle();

    expect(
      find.text(AddExistingRepoSheet.capMessage),
      findsNothing,
      reason: 'it focused a tab; nothing was refused',
    );
    expect(
      tabs.activeId,
      existing.id,
      reason:
          'the tab already on this repo is the one the user is now looking at',
    );
    expect(tabs.tabs, hasLength(2), reason: 'no second tab for one repository');
    expect(tabs.connectRan, 0, reason: 'and no second session for it either');
    // The sheet pops itself, but `_pump` mounts it as `MacosApp.home`, where
    // `Navigator.canPop()` is false — so "it closed" is not observable here for
    // ANY outcome, and asserting it would pin the harness, not the behaviour.
  });

  // MADR 0038 F4 — the sheet opens on the location the user is in. It always
  // opened on This Mac, so a user connected to a host re-picked it every time,
  // even though MADR 0036 decision 2A had already been applied to both wizards.
  group('it opens on the location the user is in (MADR 0038 F4)', () {
    testWidgets('a saved SSH session seeds that connection', (tester) async {
      await _pump(
        tester,
        connections: const [
          SavedConnection(
            id: 'c1',
            label: 'Prod',
            host: 'h',
            port: 22,
            username: 'u',
            repoPath: '/srv/repo',
            repoPaths: ['/srv/repo'],
          ),
        ],
        connection: StubConnection(connectedState()),
      );

      expect(
        tester
            .widget<MacosPopupButton<WorkspaceDestination>>(
              find.byType(MacosPopupButton<WorkspaceDestination>),
            )
            .value,
        const SavedConnectionDestination('c1'),
      );
    });

    // MADR 0038 F2 in this sheet, per deviation 2: an ad-hoc session has no id
    // to seed from, and treating that as This Mac is the same defect the
    // wizards had.
    testWidgets('an ad-hoc SSH session seeds itself', (tester) async {
      await _pump(
        tester,
        connection: StubConnection(connectedState(adHoc: true)),
      );

      expect(
        tester
            .widget<MacosPopupButton<WorkspaceDestination>>(
              find.byType(MacosPopupButton<WorkspaceDestination>),
            )
            .value,
        const ActiveSessionDestination(),
      );
    });

    testWidgets('no session at all stays on This Mac', (tester) async {
      // A disconnected session still reports the default `ssh` backend, so
      // this is not the same assertion as "a local session seeds This Mac".
      await _pump(tester);

      expect(
        tester
            .widget<MacosPopupButton<WorkspaceDestination>>(
              find.byType(MacosPopupButton<WorkspaceDestination>),
            )
            .value,
        const LocalMacDestination(),
      );
    });
  });
  // 0009 L18: a dimmed Open names the first missing field, and Enter on
  // the label field is wired to submit.
  testWidgets('Open names the first invalid field and submits on Enter', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Choose a folder'), findsOneWidget);
    final open = tester.widget<AppPushButton>(
      find.widgetWithText(AppPushButton, 'Open'),
    );
    expect(open.onPressed, isNull);
    expect(
      tester
          .widget<MacosTextField>(find.byType(MacosTextField).first)
          .onSubmitted,
      isNotNull,
    );
  });

  // 0009 L18 follow-up: Enter honors the same gate as the Open button. The
  // picked folder here has a linked-worktree gitfile, so an open that DID
  // fire would first ask for the main repository's sandbox grant — a dialog
  // this test can see, with no git process involved.
  testWidgets('Enter does not submit while Open is disabled', (tester) async {
    // Same channel mock and runAsync discipline as the prefill test below:
    // flipping the scoped toggle with a folder picked starts the real git
    // probe, whose processes never resolve inside the fake-async zone.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('appkit_ui_element_colors'),
          (call) async => <String, double>{'hueComponent': 0.6},
        );
    final temp = Directory.systemTemp.createTempSync('magic_git_l18_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final root = temp.resolveSymbolicLinksSync();
    // A linked-worktree gitfile: an open that DID fire would stop to ask for
    // the main repository's sandbox grant — a dialog this test can see.
    File(
      '$root/.git',
    ).writeAsStringSync('gitdir: $root/main/.git/worktrees/wt\n');

    await _pump(tester, initialPickedPath: root);
    final scoped = _switchNear('Scoped work-tree repo');
    await tester.ensureVisible(scoped);
    await tester.runAsync(() => tester.tap(scoped));
    await tester.pump();
    // Let the probe's processes finish; it finds no scoped layout here, so
    // the git-dir field stays empty and Open stays dimmed.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    // Scoped with an empty git-dir: Open is dimmed and says why.
    expect(find.text('Git directory is required'), findsOneWidget);
    expect(
      tester
          .widget<AppPushButton>(find.widgetWithText(AppPushButton, 'Open'))
          .onPressed,
      isNull,
    );

    final gitDir = tester.widget<MacosTextField>(
      find.byWidgetPredicate(
        (w) => w is MacosTextField && (w.placeholder ?? '').startsWith('Git '),
      ),
    );
    await tester.runAsync(() async => gitDir.onSubmitted!(''));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Grant access'), findsNothing);
    expect(find.text('Git directory is required'), findsOneWidget);
  });

  testWidgets('turning the scoped toggle on forces fsmonitor off and disables '
      'it; turning it off re-enables', (tester) async {
    await _pump(tester);

    final fsmonitor = _switchNear('Enable filesystem monitor');
    final scoped = _switchNear('Scoped work-tree repo');

    // Enable fsmonitor first so the interlock has something to clear.
    await tester.ensureVisible(fsmonitor);
    await tester.tap(fsmonitor);
    await tester.pumpAndSettle();
    expect(tester.widget<MacosSwitch>(fsmonitor).value, isTrue);

    await tester.ensureVisible(scoped);
    await tester.tap(scoped);
    await tester.pumpAndSettle();

    final locked = tester.widget<MacosSwitch>(fsmonitor);
    expect(locked.value, isFalse, reason: 'scoped must clear fsmonitor');
    expect(
      locked.onChanged,
      isNull,
      reason: 'fsmonitor must be disabled while scoped',
    );
    expect(find.textContaining('Not available for a scoped'), findsOneWidget);

    // Off again: editable once more, but stays off — no silent re-enable.
    await tester.tap(scoped);
    await tester.pumpAndSettle();
    final unlocked = tester.widget<MacosSwitch>(fsmonitor);
    expect(unlocked.value, isFalse);
    expect(unlocked.onChanged, isNotNull);
  });

  testWidgets('manually toggling scoped on pre-fills the git-dir from the '
      'picked folder', (tester) async {
    // macos_ui's AccentColorListener calls a real platform channel at MacosApp
    // mount. In an ordinary widget test the unanswered call never resolves;
    // under `runAsync` (which this test needs for real git IO) the
    // MissingPluginException actually surfaces and fails the test — answer it.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('appkit_ui_element_colors'),
          (call) async => <String, double>{'hueComponent': 0.6},
        );
    // A real bare-redirect dotfiles fixture — the probe runs real git, so the
    // whole test body runs under runAsync (real process futures never resolve
    // inside the fake-async test zone).
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('magic_git_prefill_'),
    );
    addTearDown(() => tempDir!.deleteSync(recursive: true));
    final root = tempDir!.resolveSymbolicLinksSync();
    final work = Directory('$root/home')..createSync();
    final workTree = work.resolveSymbolicLinksSync();
    final init = await tester.runAsync(
      () => Process.run('git', ['init', '--bare', '$workTree/.home.git']),
    );
    expect(init!.exitCode, 0, reason: init.stderr.toString());
    final bare = Directory('$workTree/.home.git').resolveSymbolicLinksSync();
    File('$workTree/.git').writeAsStringSync('gitdir: $bare\n');

    await _pump(tester, initialPickedPath: workTree);

    final scoped = _switchNear('Scoped work-tree repo');
    await tester.ensureVisible(scoped);
    // Tap INSIDE runAsync so the fire-and-forget probe's futures are created
    // in the real zone — real Process IO started from the fake-async zone
    // never completes.
    await tester.runAsync(() => tester.tap(scoped));
    await tester.pump();

    // Poll for the pre-filled field (the probe spawns several git processes).
    var found = false;
    for (var i = 0; i < 100 && !found; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      found = find.widgetWithText(MacosTextField, bare).evaluate().isNotEmpty;
    }
    expect(
      found,
      isTrue,
      reason: 'the git-dir field should be pre-filled with the probed git-dir',
    );
  });
  // -------------------------------------------------------------------------
  // MADR 0036 Phase 7 — the third sheet joins the shared provisioning and the
  // tab routing. It already offered every saved host; what it lacked were this
  // record's decisions, and it carried the third hand-rolled copy of the dial.
  // -------------------------------------------------------------------------
  testWidgets('Open stays on screen at the smallest window the app allows', (
    tester,
  ) async {
    // It used to sit INSIDE the scroll view, so on a short window it — and the
    // caption naming why it is disabled (0009 L18) — scrolled off the bottom,
    // where a tap dispatches to nothing at all, silently. The app's floor is
    // WindowBoundsStore.minWidth/minHeight = 640x480; at that size Open was
    // ~180 px past the edge. Create and clone pin their action row; this
    // sheet now does too.
    for (final size in [
      const Size(640, 480),
      const Size(800, 600),
      const Size(1280, 800),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await _pump(tester, initialPickedPath: '/Users/me/repo');
      final rect = tester.getRect(_openButton());
      expect(
        rect.bottom,
        lessThanOrEqualTo(size.height),
        reason: 'Open must be visible at $size without scrolling',
      );
    }
    await tester.binding.setSurfaceSize(null);
  });

  group('opening lands in its own tab (MADR 0036 Phase 7)', () {
    testWidgets('choosing a host does not dial (6B)', (tester) async {
      final stub = StubConnection(const ConnectionState());
      final tabs = RecordingTabs();
      installTabs(tabs);
      await _pump(tester, connections: [testConn], connection: stub);

      await tester.tap(find.byType(MacosPopupButton<WorkspaceDestination>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prod').last);
      await tester.pumpAndSettle();

      expect(
        stub.dialed,
        isEmpty,
        reason: 'the dial waits for the first commitment — Browse…',
      );
      expect(tabs.opened, isEmpty, reason: 'and no tab yet');
    });

    testWidgets('Browse… dials in a new tab, leaving this one alone', (
      tester,
    ) async {
      final stub = StubConnection(const ConnectionState());
      final tabs = RecordingTabs();
      installTabs(tabs);
      await _pump(tester, connections: [testConn], connection: stub);
      await tester.tap(find.byType(MacosPopupButton<WorkspaceDestination>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prod').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(AppPushButton, 'Browse…'));
      await tester.pumpAndSettle();

      expect(tabs.opened, hasLength(1), reason: 'dialled in its own tab');
      expect(tabs.spawned.single.dialed.single.id, 'c1');
      expect(
        stub.dialed,
        isEmpty,
        reason: 'the tab the sheet was opened from never dialled',
      );
    });

    testWidgets('it refuses at the tab cap and dials nothing', (tester) async {
      final stub = StubConnection(const ConnectionState());
      final tabs = RecordingTabs()..capReached = true;
      installTabs(tabs);
      await _pump(
        tester,
        initialPickedPath: '/srv/repo',
        connections: [testConn],
        connection: stub,
      );

      expect(
        tester.widget<AppPushButton>(_openButton()).onPressed,
        isNull,
        reason: 'refused up front (7A)',
      );
      expect(find.textContaining('tabs are open'), findsOneWidget);
      expect(stub.dialed, isEmpty);
      expect(tabs.connectRan, 0);
    });

    testWidgets('an unsaved local open stays in this tab (5B)', (tester) async {
      final stub = StubConnection(
        const ConnectionState(
          phase: ConnectionPhase.connected,
          backend: ConnectionBackend.local,
          repoPath: '/Users/me/other',
        ),
      );
      final tabs = RecordingTabs();
      installTabs(tabs);
      final counting = CountingScopedAccess();
      final previous = AddExistingRepoSheet.scopedAccess;
      AddExistingRepoSheet.scopedAccess = counting.access;
      addTearDown(() => AddExistingRepoSheet.scopedAccess = previous);
      await _pump(
        tester,
        initialPickedPath: '/Users/me/repo',
        connection: stub,
      );

      // Turn "Save to Local Repositories" off.
      await tester.tap(_switchNear('Save repository'));
      await tester.pumpAndSettle();
      // No ensureVisible: the action row is pinned below the scroll area now,
      // so Open is on screen at every window size the app permits.
      await tester.tap(_openButton());
      await tester.pumpAndSettle();

      expect(stub.localConnects, ['/Users/me/repo'], reason: 'opened here');
      expect(tabs.opened, isEmpty, reason: 'no bookmark, so no tab to reopen');
      expect(counting.acquired, isEmpty);
    });
  });
}
