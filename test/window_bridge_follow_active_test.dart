// The History pop-out is a SINGLE window that FOLLOWS the active tab: as the
// user switches from one repo tab to another, the window retargets to the new
// tab's repo (its proxied commands route there too), and it closes when the
// active tab has no repo to show.

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

  test('one History window follows the active tab across switches', () async {
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
        _ => null, // 'blank' / unknown → no session
      })
      ..activeTabId = (() => activeTab);

    // Pop out History from tab A → one window showing /a, serving from A.
    await bridge.openHistory();
    expect(bridge.state.map((w) => (w.kind.name, w.repoPath, w.tabId)),
        [('history', '/a', 'A')]);
    expect(
      decodeExecuteResponse(
        (await deliverHubCall('execute', encodeExecuteRequest(_req('/a'))) as Map)
            .cast<Object?, Object?>(),
      ).stdout,
      'served-by-A',
    );

    // Switch the active tab to B → the SAME window retargets to /b.
    hubCalls.clear();
    activeTab = 'B';
    bridge.onActiveTabChanged('B');

    expect(bridge.state, hasLength(1), reason: 'still one History window');
    expect(bridge.state.single.repoPath, '/b');
    expect(bridge.state.single.tabId, 'B');
    // The window was told about its new repo.
    final change = hubCalls.singleWhere((c) => c.method == 'connectionChanged');
    expect(
      ConnectionEventPayload.decode(
        (change.arguments as Map).cast<Object?, Object?>(),
      ).repoPath,
      '/b',
    );
    // And its commands now route to tab B's executor.
    expect(
      decodeExecuteResponse(
        (await deliverHubCall('execute', encodeExecuteRequest(_req('/b'))) as Map)
            .cast<Object?, Object?>(),
      ).stdout,
      'served-by-B',
    );
    expect(execB.repos, ['/b']);

    // Opening History again just fronts the one window (singleton).
    controlCalls.clear();
    await bridge.openHistory();
    expect(
      controlCalls.map((c) => c.method).where((m) => m != 'debugLog'),
      ['frontWindow'],
    );
    expect(bridge.state, hasLength(1));

    // Switching to a tab with no repo closes the follower (nothing to show).
    controlCalls.clear();
    activeTab = 'blank';
    bridge.onActiveTabChanged('blank');
    expect(
      controlCalls.where((c) => c.method == 'closeWindow').map(
        (c) => (c.arguments as Map)['windowId'],
      ),
      ['1'],
    );
  });
}
