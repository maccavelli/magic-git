// P4: each secondary window is pinned to its SPAWNING tab. Two tabs (A on /a,
// B on /b) each pop out a History window; each window's proxied commands must
// route to its own tab's executor even after the active tab switches, and
// closing a tab closes only that tab's window.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/window_manager_bridge.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._initial);
  final ConnectionState _initial;
  @override
  ConnectionState build() => _initial;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const control = MethodChannel(windowControlChannel);
  const codec = StandardMethodCodec();

  late List<MethodCall> controlCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controlCalls = [];
    messenger.setMockMethodCallHandler(control, (call) async {
      controlCalls.add(call);
      return null;
    });
    // Silence the per-window hub pushes (connectionChanged, etc.).
    for (final id in ['1', '2']) {
      messenger.setMockMethodCallHandler(
        MethodChannel(windowHubChannel(id)),
        (_) async => null,
      );
    }
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(control, null);
    for (final id in ['1', '2']) {
      messenger.setMockMethodCallHandler(MethodChannel(windowHubChannel(id)), null);
    }
  });

  Future<Object?> deliverHubCall(String id, String method, Object? args) async {
    Object? decoded;
    await messenger.handlePlatformMessage(
      windowHubChannel(id),
      codec.encodeMethodCall(MethodCall(method, args)),
      (reply) => decoded = reply == null ? null : codec.decodeEnvelope(reply),
    );
    return decoded;
  }

  test('windows pin to their spawning tab; commands route there after a switch '
      'and closing a tab closes only its window', () async {
    final execA = _FakeExecutor('A');
    final execB = _FakeExecutor('B');
    final containerA = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(() => _StubConnection(_connected('/a'))),
        activeExecutorProvider.overrideWithValue(execA),
      ],
    );
    final containerB = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(() => _StubConnection(_connected('/b'))),
        activeExecutorProvider.overrideWithValue(execB),
      ],
    );
    final bridgeContainer = ProviderContainer();
    addTearDown(containerA.dispose);
    addTearDown(containerB.dispose);
    addTearDown(bridgeContainer.dispose);

    var activeTab = 'A';
    final bridge = bridgeContainer.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((tabId) => switch (tabId) {
        'A' => containerA,
        'B' => containerB,
        _ => null,
      })
      ..activeTabId = (() => activeTab);

    // Tab A pops out History → window '1' pinned to A, showing /a.
    await bridge.openHistory();
    // Switch the active tab to B and pop out again → window '2' pinned to B.
    activeTab = 'B';
    await bridge.openHistory();

    final opened = controlCalls.where((c) => c.method == 'openWindow').toList();
    expect(opened, hasLength(2), reason: 'a separate window per tab');
    expect((opened[0].arguments as Map)['repoPath'], '/a');
    expect((opened[1].arguments as Map)['repoPath'], '/b');
    expect(bridge.state.map((w) => (w.tabId, w.repoPath)),
        [('A', '/a'), ('B', '/b')]);

    // Even though B is the active tab now, window '1' still serves tab A.
    final req = encodeExecuteRequest(
      const ExecuteRequest(
        repoPath: '/a',
        gitArgs: ['git', 'log'],
        timeout: Duration(seconds: 30),
        retries: 0,
        lane: ExecLane.read,
        compress: false,
      ),
    );
    final replyA = await deliverHubCall('1', 'execute', req);
    expect(
      decodeExecuteResponse((replyA as Map).cast<Object?, Object?>()).stdout,
      'served-by-A',
      reason: 'window 1 stays pinned to tab A regardless of the active tab',
    );
    expect(execA.repos, ['/a']);
    expect(execB.repos, isEmpty);

    final reqB = encodeExecuteRequest(
      const ExecuteRequest(
        repoPath: '/b',
        gitArgs: ['git', 'log'],
        timeout: Duration(seconds: 30),
        retries: 0,
        lane: ExecLane.read,
        compress: false,
      ),
    );
    final replyB = await deliverHubCall('2', 'execute', reqB);
    expect(
      decodeExecuteResponse((replyB as Map).cast<Object?, Object?>()).stdout,
      'served-by-B',
    );

    // A hub call whose tab's container can no longer be resolved (host unwired
    // it, or the tab is mid-teardown) replies RELAY_DOWN — the child treats it
    // as "window on its way out".
    bridge.sessionContainerFor = (_) => null;
    await expectLater(
      deliverHubCall('2', 'execute', reqB),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'RELAY_DOWN'),
      ),
    );
    // Re-wire so onTabClosed can still run its native closes.
    bridge.sessionContainerFor = ((tabId) => switch (tabId) {
      'A' => containerA,
      'B' => containerB,
      _ => null,
    });

    // Closing tab A closes only window '1' and forgets it.
    controlCalls.clear();
    bridge.onTabClosed('A');
    expect(
      controlCalls.where((c) => c.method == 'closeWindow').map(
        (c) => (c.arguments as Map)['windowId'],
      ),
      ['1'],
    );
    expect(bridge.state.map((w) => w.id), ['2'],
        reason: 'window 2 (tab B) survives');
  });
}
