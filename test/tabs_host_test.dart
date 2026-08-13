// TabsHost mounts exactly one tab's AppShell at a time and owns the native
// menu channel + window lifecycle stably across switches. These tests guard the
// two riskiest parts of the host/AppShell split:
//   1. The tab strip is invisible with one tab (zero UX change) and appears
//      browser-style with two.
//   2. The `magicgit/menu` channel keeps routing to the ACTIVE tab AFTER a
//      switch — the dispose-clobber regression that moving the handler out of
//      the (remounting) AppShell and into the stable host is meant to prevent.

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/window_manager_bridge.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/tabs/tab_ui_providers.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:remote_magic_git/features/tabs/tabs_host.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

class _Disconnected extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState();
}

/// A disconnected session carrying a distinctive marker (so a sheet reading
/// connectionProvider can be shown to resolve THIS tab container, not root).
class _MarkedConn extends ConnectionController {
  _MarkedConn(this.marker);
  final String marker;
  @override
  ConnectionState build() => ConnectionState(host: marker);
}

class _Connected extends ConnectionController {
  _Connected(this.initial);
  final ConnectionState initial;

  @override
  ConnectionState build() => initial;
}

/// Each tab is its own root container with a disconnected session (so AppShell
/// renders the lightweight ConnectionLanding) and stubbed saved-lists/forge so
/// nothing reaches disk or a real executor.
ProviderContainer _tabContainer(List<Override> overrides) => ProviderContainer(
  retry: (_, _) => null,
  overrides: [
    connectionProvider.overrideWith(_Disconnected.new),
    savedConnectionsProvider.overrideWith((ref) => const []),
    savedLocalReposProvider.overrideWith((ref) => const []),
    forgeRepoListProvider.overrideWith((ref, key) async => const []),
    forgeAuthHostProvider.overrideWith((ref, key) async => null),
    ...overrides,
  ],
);

// MacosIcon renders a RichText, not a Flutter Icon, so find.byIcon never
// matches it — match on the MacosIcon's `icon` field instead.
Finder _findMacosIcon(IconData icon) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == icon);

Future<void> _sendMenu(WidgetTester tester, String method) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'magicgit/menu',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );
  await tester.pump();
}

// Plugin channels absent in tests. window_manager backs the host's window
// lifecycle; macos_window_utils backs MacosWindow's vibrancy subview (which
// also schedules an untracked zero-duration Timer per build — drained by
// [_teardownHost] before teardown).
const _windowManager = MethodChannel('window_manager');
const _macosWindowUtils = MethodChannel(
  'macos_window_utils/window_manipulator',
);

Future<void> _pumpHost(WidgetTester tester, TabsController c) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  for (final channel in const [_windowManager, _macosWindowUtils]) {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }
  // TabsHost now owns MacosApp and watches the bridge, so it needs a
  // ProviderScope ancestor (the app's root container).
  await tester.pumpWidget(ProviderScope(child: TabsHost(controller: c)));
  await tester.pumpAndSettle();
}

/// Tears the host down cleanly inside the test body so no `Timer` is pending at
/// the framework's end-of-test invariant check. Two independent leaks:
///   1. MacosWindow's vibrancy subview schedules an untracked `Timer(zero)` on
///      each build (macos_window_utils) — drained here while still mounted (its
///      callback needs the live render object, so it must fire before unmount).
///   2. Unmounting closes the host's `windowTitleProvider` (autoDispose)
///      subscription, which arms Riverpod's dispose scheduler `Timer` — drained
///      after unmounting the tree.
Future<void> _teardownHost(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 10)); // fire vibrancy timers
  await tester.pumpWidget(const SizedBox()); // unmount → TabsHost.dispose
  await tester.pump(const Duration(milliseconds: 10)); // fire Riverpod dispose
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a single tab shows no tab-strip chrome (zero UX change)', (
    tester,
  ) async {
    final c = TabsController(containerFactory: _tabContainer);
    addTearDown(c.dispose);
    await _pumpHost(tester, c);

    // The landing renders, and there is no "+" (the strip is hidden at 1 tab).
    expect(find.text('Connections Manager'), findsOneWidget);
    expect(_findMacosIcon(CupertinoIcons.add), findsNothing);
    await _teardownHost(tester);
  });

  testWidgets('opening a second repo shows a browser-style two-chip strip', (
    tester,
  ) async {
    final c = TabsController(containerFactory: _tabContainer);
    addTearDown(c.dispose);
    c.ensureInitialTab();
    c.openOrFocus(connectionId: 'a', repoPath: '/repo-alpha', connect: (_) {});
    c.openOrFocus(connectionId: 'b', repoPath: '/repo-beta', connect: (_) {});
    await _pumpHost(tester, c);

    expect(find.text('repo-alpha'), findsOneWidget);
    expect(find.text('repo-beta'), findsOneWidget);
    // The "+" (new-tab) affordance is present with a multi-tab strip.
    expect(_findMacosIcon(CupertinoIcons.add), findsOneWidget);
    await _teardownHost(tester);
  });

  testWidgets(
    'a stable alias replaces the repository basename in the tab strip',
    (tester) async {
      final c = TabsController(containerFactory: _tabContainer);
      addTearDown(c.dispose);
      c.ensureInitialTab();
      final alpha = c.openOrFocus(
        connectionId: 'a',
        repoPath: '/repo-alpha',
        savedKind: SavedRepositoryKind.ssh,
        connect: (_) {},
      );
      c.openOrFocus(
        connectionId: 'b',
        repoPath: '/repo-beta',
        savedKind: SavedRepositoryKind.ssh,
        connect: (_) {},
      );
      await c.setAlias(alpha, 'API');
      await _pumpHost(tester, c);

      expect(find.text('API'), findsOneWidget);
      expect(find.text('repo-alpha'), findsNothing);
      await _teardownHost(tester);
    },
  );

  test(
    'window title uses the tab alias without changing repository identity',
    () async {
      const repo = '/srv/repository';
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          connectionProvider.overrideWith(
            () => _Connected(
              const ConnectionState(
                phase: ConnectionPhase.connected,
                connectionId: 'saved',
                repoPath: repo,
                repoPaths: [repo],
              ),
            ),
          ),
          statusProvider(repo).overrideWith(
            (ref) async => GitStatus(
              branch: const GitBranchInfo(head: 'main'),
              files: const [],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(tabAliasProvider.notifier).set('Backend');
      await container.read(statusProvider(repo).future);

      expect(container.read(windowTitleProvider), 'Backend (main) — Magic Git');
      expect(container.read(connectionProvider).repoPath, repo);
    },
  );

  testWidgets('the History bridge is wired to the tab controller after mount', (
    tester,
  ) async {
    final c = TabsController(containerFactory: _tabContainer);
    addTearDown(c.dispose);
    await _pumpHost(tester, c);

    // The bridge (built during MacosApp's first build) must have its
    // resolvers wired to the controller — otherwise openHistory() gates out
    // with "no session container" and no window ever launches.
    final bridge = WindowManagerBridge.current;
    expect(bridge, isNotNull);
    expect(
      bridge!.activeTabId(),
      c.activeId,
      reason: 'activeTabId resolver is wired',
    );
    expect(
      bridge.sessionContainerFor(c.activeId),
      same(c.active!.container),
      reason: 'sessionContainerFor resolver is wired',
    );
    await _teardownHost(tester);
  });

  testWidgets(
    'a sheet on the root navigator reads the active tab session, not root',
    (tester) async {
      final c = TabsController(
        containerFactory: (overrides) => ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            connectionProvider.overrideWith(() => _MarkedConn('TAB-MARKER')),
            savedConnectionsProvider.overrideWith((ref) => const []),
            savedLocalReposProvider.overrideWith((ref) => const []),
            forgeRepoListProvider.overrideWith((ref, key) async => const []),
            forgeAuthHostProvider.overrideWith((ref, key) async => null),
            ...overrides,
          ],
        ),
      );
      addTearDown(c.dispose);
      await _pumpHost(tester, c);

      // Push a sheet exactly as the commit dialog does — on the root navigator,
      // from an AppShell context — and capture what connectionProvider it sees.
      String? seenHost;
      final ctx = tester.element(find.byType(AppShell));
      unawaited(
        showMacosSheet<void>(
          context: ctx,
          builder: (_) => Consumer(
            builder: (_, ref, _) {
              seenHost = ref.watch(connectionProvider).host;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        seenHost,
        'TAB-MARKER',
        reason: 'the sheet resolved the active tab container, not empty root',
      );
      await _teardownHost(tester);
    },
  );

  testWidgets(
    'the menu channel keeps routing to the active tab after a switch',
    (tester) async {
      final c = TabsController(containerFactory: _tabContainer);
      addTearDown(c.dispose);
      c.ensureInitialTab();
      c.openOrFocus(
        connectionId: 'a',
        repoPath: '/repo-alpha',
        connect: (_) {},
      );
      c.openOrFocus(connectionId: 'b', repoPath: '/repo-beta', connect: (_) {});
      await _pumpHost(tester, c);

      final tabA = c.tabs[0];
      final tabB = c.tabs[1];
      expect(c.activeId, tabB.id, reason: 'the newest tab is active');

      final bBefore = tabB.container.read(outputLogProvider).visible;
      await _sendMenu(tester, 'toggleOutputView');
      expect(
        tabB.container.read(outputLogProvider).visible,
        !bBefore,
        reason: 'the menu toggled the ACTIVE tab (B)',
      );
      // Tab A, in the background, is untouched.
      final aInitial = tabA.container.read(outputLogProvider).visible;

      // Switch to tab A by tapping its chip.
      await tester.tap(find.text('repo-alpha'));
      await tester.pumpAndSettle();
      expect(c.activeId, tabA.id);

      // The handler survived the AppShell remount and now routes to A.
      await _sendMenu(tester, 'toggleOutputView');
      expect(
        tabA.container.read(outputLogProvider).visible,
        !aInitial,
        reason: 'the menu now toggles the newly-active tab (A)',
      );
      // Tab B keeps the value it had — the switch didn't leak across tabs.
      expect(tabB.container.read(outputLogProvider).visible, !bBefore);
      await _teardownHost(tester);
    },
  );
}
