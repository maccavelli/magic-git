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
import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart' show PendingOp;
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/window_manager_bridge.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
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

/// Answers every command with a clean empty result, so a container holding a
/// *connected* session never reaches a real SSH client.
class _QuietExecutor extends SSHCommandExecutor {
  _QuietExecutor() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async => const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
}

/// Each tab is its own root container with a disconnected session (so AppShell
/// renders the lightweight ConnectionLanding) and stubbed saved-lists/forge so
/// nothing reaches disk or a real executor.
ProviderContainer _tabContainer(List<Override> overrides) => ProviderContainer(
  retry: (_, _) => null,
  overrides: [
    executorProvider.overrideWithValue(_QuietExecutor()),
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

  testWidgets('middle-clicking a tab chip closes that tab', (tester) async {
    final c = TabsController(containerFactory: _tabContainer);
    addTearDown(c.dispose);
    c.ensureInitialTab();
    c.openOrFocus(connectionId: 'a', repoPath: '/repo-alpha', connect: (_) {});
    c.openOrFocus(connectionId: 'b', repoPath: '/repo-beta', connect: (_) {});
    c.openOrFocus(connectionId: 'c', repoPath: '/repo-gamma', connect: (_) {});
    await _pumpHost(tester, c);

    expect(c.tabs, hasLength(3));
    await tester.tap(find.text('repo-alpha'), buttons: kMiddleMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('repo-alpha'), findsNothing);
    expect(find.text('repo-beta'), findsOneWidget);
    expect(find.text('repo-gamma'), findsOneWidget);
    expect(c.tabs.map((tab) => tab.repoPath), ['/repo-beta', '/repo-gamma']);
    await _teardownHost(tester);
  });

  testWidgets('a dirty tab shows an uncommitted-changes badge', (tester) async {
    final handle = tester.ensureSemantics();
    final c = TabsController(
      containerFactory: (overrides) => _tabContainer([
        statusProvider('/repo-alpha').overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'main'),
            files: const [
              GitFileStatus(path: 'a.txt', statusX: 'M', statusY: '.'),
            ],
          ),
        ),
        statusProvider('/repo-beta').overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'main'),
            files: const [],
          ),
        ),
        ...overrides,
      ]),
    );
    addTearDown(c.dispose);
    c.ensureInitialTab();
    c.openOrFocus(connectionId: 'a', repoPath: '/repo-alpha', connect: (_) {});
    c.openOrFocus(connectionId: 'b', repoPath: '/repo-beta', connect: (_) {});
    await _pumpHost(tester, c);

    final alpha = c.tabs.firstWhere((tab) => tab.repoPath == '/repo-alpha');
    expect(
      alpha.container.read(statusProvider('/repo-alpha')).asData!.value.isClean,
      isFalse,
    );
    expect(find.byKey(const ValueKey('tab-dirty-/repo-alpha')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-dirty-/repo-beta')), findsNothing);
    expect(
      tester.getSemantics(find.text('repo-alpha')).label,
      contains('uncommitted changes'),
    );
    handle.dispose();
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

  testWidgets('the quit guard shows its confirmation on the root navigator', (
    tester,
  ) async {
    // Regression: the guard used to be shown with TabsHost's OWN context, which
    // sits ABOVE the MacosApp it builds — so Navigator.of() threw and the
    // dialog never appeared. ⌘Q/red-button/Dock-quit all declined termination
    // waiting for an answer that could never come, leaving the app unquittable
    // except by Force Quit.
    const repo = '/repo-dirty';
    var created = 0;
    final c = TabsController(
      containerFactory: (overrides) {
        // The FIRST container is the connected, dirty tab (openOrFocus reuses
        // the blank initial tab for it); the second is a plain disconnected tab
        // that stays active, so only the light ConnectionLanding ever mounts.
        if (created++ != 0) return _tabContainer(overrides);
        return ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            executorProvider.overrideWithValue(_QuietExecutor()),
            activeExecutorProvider.overrideWithValue(_QuietExecutor()),
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
                files: const [
                  GitFileStatus(path: 'a.txt', statusX: 'M', statusY: '.'),
                ],
              ),
            ),
            pendingOpProvider(repo).overrideWith((ref) async => PendingOp.none),
            savedConnectionsProvider.overrideWith((ref) => const []),
            savedLocalReposProvider.overrideWith((ref) => const []),
            forgeRepoListProvider.overrideWith((ref, key) async => const []),
            forgeAuthHostProvider.overrideWith((ref, key) async => null),
            ...overrides,
          ],
        );
      },
    );
    addTearDown(c.dispose);
    c.ensureInitialTab();
    final dirty = c.openOrFocus(
      connectionId: 'a',
      repoPath: repo,
      connect: (_) {},
    );
    c.openOrFocus(connectionId: 'b', repoPath: '/repo-plain', connect: (_) {});
    // sessionsAtRisk reads only ALREADY-LANDED status, so let it land — and
    // hold a subscription so the autoDispose provider doesn't drop the value
    // again before the guard reads it.
    final keepAlive = dirty.container.listen<AsyncValue<GitStatus>>(
      statusProvider(repo),
      (_, _) {},
    );
    addTearDown(keepAlive.close);
    await dirty.container.read(statusProvider(repo).future);
    await _pumpHost(tester, c);

    expect(
      dirty.container.read(statusProvider(repo)).value?.isClean,
      isFalse,
      reason: 'the background tab must be at risk for the guard to run',
    );
    await _sendMenu(tester, 'prepareToTerminate');
    await tester.pumpAndSettle();

    expect(find.text('Quit Magic Git?'), findsOneWidget);
    expect(find.textContaining(repo), findsOneWidget);

    // Cancel, so no teardown runs against the test's mock channels.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Quit Magic Git?'), findsNothing);
    await _teardownHost(tester);
  });

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
