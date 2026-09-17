// The History pop-out is a SINGLE window that FOLLOWS the active tab: as the
// user switches from one repo tab to another it retargets to the new tab's repo
// (commands route there too). Crucially, opening a brand-new repo — whose tab is
// activated synchronously but connects a beat later — must NOT close the window;
// it waits for the tab to connect, then retargets.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/window_manager_bridge.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';
import 'package:remote_magic_git/core/window/window_kind.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MutableConnection extends ConnectionController {
  _MutableConnection(this._initial);
  final ConnectionState _initial;
  @override
  ConnectionState build() => _initial;
  void set(ConnectionState next) => state = next;
}

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor(this.tag) : super(SSHClientManager());
  final String tag;
  final List<String> repos = [];

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
  }) async {
    repos.add(repoPath);
    return SSHCommandResult(exitCode: 0, stdout: 'served-by-$tag', stderr: '');
  }
}

ConnectionState _connected(String repo) => ConnectionState(
  phase: ConnectionPhase.connected,
  repoPath: repo,
  connectionLabel: repo,
  host: 'h',
);

ExecuteRequest _req(String repo) => ExecuteRequest(
  repoPath: repo,
  gitArgs: const ['git', 'log'],
  timeout: const Duration(seconds: 30),
  retries: 0,
  lane: ExecLane.read,
  compress: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const control = MethodChannel(windowControlChannel);
  final hub1 = MethodChannel(windowHubChannel('1'));
  const codec = StandardMethodCodec();

  late List<MethodCall> controlCalls;
  late List<MethodCall> hubCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controlCalls = [];
    hubCalls = [];
    messenger.setMockMethodCallHandler(control, (call) async {
      controlCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(hub1, (call) async {
      hubCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(control, null);
    messenger.setMockMethodCallHandler(hub1, null);
  });

  Future<Object?> deliverHubCall(String method, Object? args) async {
    Object? decoded;
    await messenger.handlePlatformMessage(
      windowHubChannel('1'),
      codec.encodeMethodCall(MethodCall(method, args)),
      (reply) => decoded = reply == null ? null : codec.decodeEnvelope(reply),
    );
    return decoded;
  }

  String repoOf(MethodCall change) => ConnectionEventPayload.decode(
    (change.arguments as Map).cast<Object?, Object?>(),
  ).repoPath!;

  test('History follows the active tab; a still-connecting new repo does not '
      'close it — it retargets once connected', () async {
    final execA = _FakeExecutor('A');
    final execB = _FakeExecutor('B');
    final stubB = _MutableConnection(const ConnectionState()); // connecting
    final containerA = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/a')),
        ),
        activeExecutorProvider.overrideWithValue(execA),
      ],
    );
    final containerB = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(() => stubB),
        activeExecutorProvider.overrideWithValue(execB),
      ],
    );
    final bridgeContainer = ProviderContainer();
    addTearDown(containerA.dispose);
    addTearDown(containerB.dispose);
    addTearDown(bridgeContainer.dispose);

    var activeTab = 'A';
    final tabs = {'A': containerA, 'B': containerB};
    final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((tabId) => tabs[tabId])
      ..activeTabId = (() => activeTab);

    // Pop out History from tab A → one window showing /a.
    await bridge.openHistory();
    expect(bridge.state.single.repoPath, '/a');

    // Open a new repo B: its tab is activated synchronously but not yet
    // connected. The window must NOT close — it stays on /a and waits.
    hubCalls.clear();
    activeTab = 'B';
    bridge.onActiveTabChanged('B', isBlank: false);
    expect(bridge.state, hasLength(1), reason: 'the window is not closed');
    expect(
      bridge.state.single.repoPath,
      '/a',
      reason: 'still on A until B connects',
    );
    expect(hubCalls.where((c) => c.method == 'connectionChanged'), isEmpty);

    // B finishes connecting → the window retargets to /b.
    stubB.set(_connected('/b'));
    await containerB.pump();
    expect(bridge.state.single.repoPath, '/b');
    expect(bridge.state.single.tabId, 'B');
    expect(
      repoOf(hubCalls.singleWhere((c) => c.method == 'connectionChanged')),
      '/b',
    );
    expect(
      decodeExecuteResponse(
        (await deliverHubCall('execute', encodeExecuteRequest(_req('/b')))
                as Map)
            .cast<Object?, Object?>(),
      ).stdout,
      'served-by-B',
    );

    // Opening History again just fronts the one window (singleton).
    controlCalls.clear();
    await bridge.openHistory();
    expect(controlCalls.map((c) => c.method).where((m) => m != 'debugLog'), [
      'frontWindow',
    ]);
    expect(bridge.state, hasLength(1));
  });

  test('an already-connected switch retargets immediately; visiting a landing '
      'tab keeps the window, but closing the followed repo closes it', () async {
    final containerA = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/a')),
        ),
        activeExecutorProvider.overrideWithValue(_FakeExecutor('A')),
      ],
    );
    final containerB = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/b')),
        ),
        activeExecutorProvider.overrideWithValue(_FakeExecutor('B')),
      ],
    );
    final bridgeContainer = ProviderContainer();
    addTearDown(containerA.dispose);
    addTearDown(containerB.dispose);
    addTearDown(bridgeContainer.dispose);

    var activeTab = 'A';
    // A live map so a tab can be "closed" by dropping its container.
    final tabs = <String, ProviderContainer>{'A': containerA, 'B': containerB};
    final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((tabId) => tabs[tabId])
      ..activeTabId = (() => activeTab);

    await bridge.openHistory();
    activeTab = 'B';
    bridge.onActiveTabChanged('B', isBlank: false);
    expect(
      bridge.state.single.repoPath,
      '/b',
      reason: 'connected → retarget now',
    );

    // Visit a blank landing tab while B is still open → keep the window (the
    // user is just between repos).
    activeTab = 'landing';
    bridge.onActiveTabChanged('landing', isBlank: true);
    expect(
      bridge.state,
      hasLength(1),
      reason: 'followed repo (B) is still open',
    );

    // Now the followed repo's tab (B) is closed. Its window is detached, and
    // switching to the blank landing tab closes the follower (nothing to show).
    bridge.onTabClosed('B');
    tabs.remove('B');
    controlCalls.clear();
    activeTab = 'landing';
    bridge.onActiveTabChanged('landing', isBlank: true);
    expect(
      controlCalls
          .where((c) => c.method == 'closeWindow')
          .map((c) => (c.arguments as Map)['windowId']),
      ['1'],
    );
  });

  test(
    'proxied execute routes by the repo in the request, not the pinned tab',
    () async {
      final execA = _FakeExecutor('A');
      final execB = _FakeExecutor('B');
      final containerA = ProviderContainer(
        overrides: [
          connectionProvider.overrideWith(
            () => _MutableConnection(_connected('/a')),
          ),
          activeExecutorProvider.overrideWithValue(execA),
        ],
      );
      final containerB = ProviderContainer(
        overrides: [
          connectionProvider.overrideWith(
            () => _MutableConnection(_connected('/b')),
          ),
          activeExecutorProvider.overrideWithValue(execB),
        ],
      );
      final bridgeContainer = ProviderContainer();
      addTearDown(containerA.dispose);
      addTearDown(containerB.dispose);
      addTearDown(bridgeContainer.dispose);

      var activeTab = 'A';
      final byTab = {'A': containerA, 'B': containerB};
      final byRepo = {'/a': containerA, '/b': containerB};
      final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
        ..sessionContainerFor = ((t) => byTab[t])
        ..activeTabId = (() => activeTab)
        ..containerForRepo = ((repo) => byRepo[repo]);

      await bridge.openHistory(); // pinned to A
      activeTab = 'B';
      bridge.onActiveTabChanged('B', isBlank: false);
      expect(
        bridge.state.single.tabId,
        'B',
        reason: 'window now follows tab B',
      );

      // A lagging request for the OLD repo (/a) — still open in tab A — must route
      // to tab A's session, NOT the now-pinned tab B (which would run git -C /a on
      // the wrong host and fail). This is the switch-time diff bug.
      final replyA = await deliverHubCall(
        'execute',
        encodeExecuteRequest(_req('/a')),
      );
      expect(
        decodeExecuteResponse((replyA as Map).cast<Object?, Object?>()).stdout,
        'served-by-A',
      );
      expect(execA.repos, ['/a']);
      expect(execB.repos, isEmpty);

      // A request for the new repo (/b) routes to tab B.
      await deliverHubCall('execute', encodeExecuteRequest(_req('/b')));
      expect(execB.repos, ['/b']);
    },
  );

  test('execute prefers the pinned tab when it owns the repo, and never runs '
      'against a session that does not own the repo', () async {
    final execA = _FakeExecutor('A');
    final execB = _FakeExecutor('B');
    // Both tabs' sessions claim the SAME path /shared (same working-tree path on
    // two different hosts) — a repo path is not globally unique.
    final containerA = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/shared')),
        ),
        activeExecutorProvider.overrideWithValue(execA),
      ],
    );
    final containerB = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/shared')),
        ),
        activeExecutorProvider.overrideWithValue(execB),
      ],
    );
    final bridgeContainer = ProviderContainer();
    addTearDown(containerA.dispose);
    addTearDown(containerB.dispose);
    addTearDown(bridgeContainer.dispose);

    const activeTab = 'B';
    final byTab = {'A': containerA, 'B': containerB};
    final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((t) => byTab[t])
      ..activeTabId = (() => activeTab)
      // containerForRepo returns tab A first for /shared (it's the first tab
      // that holds the path) — the routing must NOT blindly trust this.
      ..containerForRepo = ((repo) => repo == '/shared' ? containerA : null);

    // History pop-out pinned to tab B.
    await bridge.openHistory();
    expect(bridge.state.single.tabId, 'B');

    // /shared is owned by the pinned tab B → route to B, NOT to A (which
    // containerForRepo would hand back first). Wrong-host hazard avoided.
    await deliverHubCall('execute', encodeExecuteRequest(_req('/shared')));
    expect(execB.repos, ['/shared'], reason: 'pinned owner wins the tie');
    expect(execA.repos, isEmpty);

    // A repo NO open session owns must NOT fall back to the pinned session
    // (that would run git against the wrong repo/host) — it RELAY_DOWNs, so
    // neither executor runs it.
    try {
      await deliverHubCall('execute', encodeExecuteRequest(_req('/gone')));
    } catch (_) {
      // RELAY_DOWN surfaces as a decode error on the reply — expected.
    }
    expect(execA.repos, isEmpty, reason: 'the unowned repo ran nowhere');
    expect(execB.repos, [
      '/shared',
    ], reason: 'only the earlier owned request ran');
  });

  test('a detachedRepo window routes to its own pinned tab for a path no tab '
      'owns (MADR 0047)', () async {
    final execA = _FakeExecutor('A');
    final containerA = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/a')),
        ),
        activeExecutorProvider.overrideWithValue(execA),
      ],
    );
    final bridgeContainer = ProviderContainer();
    addTearDown(containerA.dispose);
    addTearDown(bridgeContainer.dispose);

    const activeTab = 'A';
    final byTab = {'A': containerA};
    final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((t) => byTab[t])
      ..activeTabId = (() => activeTab)
      // No open tab holds the worktree path — the case `_sessionOwns` and
      // `containerForRepo` both refuse today.
      ..containerForRepo = ((_) => null);

    // Detached window opened from tab A, pinned to a linked worktree — a path
    // that is neither tab A's active repo nor in any session's `repoPaths`.
    await bridge.openDetachedRepo('/repo/wt');
    expect(bridge.state.single.kind, WindowKind.detachedRepo);
    expect(bridge.state.single.repoPath, '/repo/wt');
    expect(bridge.state.single.tabId, 'A');

    final reply = await deliverHubCall(
      'execute',
      encodeExecuteRequest(_req('/repo/wt')),
    );
    expect(
      decodeExecuteResponse((reply as Map).cast<Object?, Object?>()).stdout,
      'served-by-A',
      reason:
          'the window\'s own pin routes to its pinned tab, where today '
          'this RELAY_DOWNs',
    );
    expect(execA.repos, ['/repo/wt']);
  });

  test(
    "a detachedRepo window's own pin still wins with a second, unrelated tab "
    'open',
    () async {
      final execA = _FakeExecutor('A');
      final execB = _FakeExecutor('B');
      final containerA = ProviderContainer(
        overrides: [
          connectionProvider.overrideWith(
            () => _MutableConnection(_connected('/a')),
          ),
          activeExecutorProvider.overrideWithValue(execA),
        ],
      );
      final containerB = ProviderContainer(
        overrides: [
          connectionProvider.overrideWith(
            () => _MutableConnection(_connected('/b')),
          ),
          activeExecutorProvider.overrideWithValue(execB),
        ],
      );
      final bridgeContainer = ProviderContainer();
      addTearDown(containerA.dispose);
      addTearDown(containerB.dispose);
      addTearDown(bridgeContainer.dispose);

      const activeTab = 'A';
      final byTab = {'A': containerA, 'B': containerB};
      final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
        ..sessionContainerFor = ((t) => byTab[t])
        ..activeTabId = (() => activeTab)
        ..containerForRepo = ((_) => null);

      await bridge.openDetachedRepo('/repo/wt');
      expect(bridge.state.single.tabId, 'A');

      await deliverHubCall('execute', encodeExecuteRequest(_req('/repo/wt')));
      expect(execA.repos, ['/repo/wt'], reason: 'routed to the pinned tab');
      expect(
        execB.repos,
        isEmpty,
        reason: 'an unrelated open tab never runs the window\'s command',
      );
    },
  );

  test('a detachedRepo window asking for a path that is not its own pin still '
      'gets RELAY_DOWN', () async {
    final execA = _FakeExecutor('A');
    final containerA = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => _MutableConnection(_connected('/a')),
        ),
        activeExecutorProvider.overrideWithValue(execA),
      ],
    );
    final bridgeContainer = ProviderContainer();
    addTearDown(containerA.dispose);
    addTearDown(bridgeContainer.dispose);

    const activeTab = 'A';
    final byTab = {'A': containerA};
    final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((t) => byTab[t])
      ..activeTabId = (() => activeTab)
      ..containerForRepo = ((_) => null);

    await bridge.openDetachedRepo('/repo/wt');

    var threw = false;
    try {
      await deliverHubCall(
        'execute',
        encodeExecuteRequest(_req('/somewhere/else')),
      );
    } catch (_) {
      // RELAY_DOWN surfaces as a decode error on the reply — expected.
      threw = true;
    }
    expect(
      threw,
      isTrue,
      reason:
          'the own-pin exception is scoped to the window\'s own pin, not a '
          'general relaxation',
    );
    expect(execA.repos, isEmpty);
  });
}
