// The main-isolate end of the native History window: gated open, execute
// serving (success + typed errors), undo-record absorption into the real
// journal, mutation-driven refresh marks, Recovery forwarding, and
// close-on-disconnect.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/history_window_bridge.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/undo/undo_journal.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

const _control = MethodChannel('magicgit/history');
const _hub = MethodChannel('magicgit/history/hub');
const _codec = StandardMethodCodec();

class _StubConnection extends ConnectionController {
  _StubConnection(this._initial);
  final ConnectionState _initial;

  @override
  ConnectionState build() => _initial;

  void set(ConnectionState next) => state = next;
}

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor() : super(SSHClientManager());
  final List<List<String>> calls = [];
  Object? throwNext;

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
    calls.add(gitArgs);
    final error = throwNext;
    if (error != null) {
      throwNext = null;
      throw error;
    }
    return const SSHCommandResult(exitCode: 0, stdout: 'served', stderr: '');
  }
}

const _connected = ConnectionState(
  phase: ConnectionPhase.connected,
  repoPath: '/srv/repo',
  connectionLabel: 'Prod',
  host: 'bastion',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late ProviderContainer container;
  late _StubConnection stub;
  late _FakeExecutor executor;
  late List<MethodCall> controlCalls;
  late List<MethodCall> hubCalls;

  ProviderContainer makeContainer(ConnectionState initial) {
    stub = _StubConnection(initial);
    executor = _FakeExecutor();
    final c = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(() => stub),
        activeExecutorProvider.overrideWithValue(executor),
      ],
    );
    addTearDown(c.dispose);
    // Activate the bridge (installs channel handlers, connection listener).
    c.read(historyWindowBridgeProvider);
    return c;
  }

  /// Simulates the relay delivering a call from the History isolate and
  /// returns the decoded reply.
  Future<Object?> deliverHubCall(String method, Object? arguments) async {
    Object? decoded;
    await messenger.handlePlatformMessage(
      'magicgit/history/hub',
      _codec.encodeMethodCall(MethodCall(method, arguments)),
      (reply) => decoded = reply == null ? null : _codec.decodeEnvelope(reply),
    );
    return decoded;
  }

  Future<void> deliverControlCall(String method) async {
    await messenger.handlePlatformMessage(
      'magicgit/history',
      _codec.encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  setUp(() {
    controlCalls = [];
    hubCalls = [];
    messenger.setMockMethodCallHandler(_control, (call) async {
      controlCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(_hub, (call) async {
      hubCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_control, null);
    messenger.setMockMethodCallHandler(_hub, null);
  });

  test('open() asks Swift for the window only while a repo is active', () async {
    container = makeContainer(_connected);
    await container.read(historyWindowBridgeProvider.notifier).open();
    expect(controlCalls.map((c) => c.method), ['openHistoryWindow']);
    expect(container.read(historyWindowBridgeProvider), isTrue);

    controlCalls.clear();
    stub.set(const ConnectionState()); // disconnected
    await container.read(historyWindowBridgeProvider.notifier).open();
    expect(
      controlCalls.map((c) => c.method),
      isNot(contains('openHistoryWindow')),
    );
  });

  test('serves execute calls: success and each typed error as envelopes',
      () async {
    container = makeContainer(_connected);
    final request = encodeExecuteRequest(
      const ExecuteRequest(
        repoPath: '/srv/repo',
        gitArgs: ['git', 'log'],
        timeout: Duration(seconds: 30),
        retries: 1,
        lane: ExecLane.read,
        compress: true,
      ),
    );

    final ok = await deliverHubCall('execute', request);
    final result = decodeExecuteResponse(
      (ok as Map).cast<Object?, Object?>(),
    );
    expect(result.stdout, 'served');
    expect(executor.calls.single, ['git', 'log']);

    executor.throwNext = const SSHCommandTimeout('git log');
    final timedOut = await deliverHubCall('execute', request);
    expect(
      () => decodeExecuteResponse((timedOut as Map).cast<Object?, Object?>()),
      throwsA(isA<SSHCommandTimeout>()),
    );

    executor.throwNext = StateError('boom');
    final other = await deliverHubCall('execute', request);
    expect(
      () => decodeExecuteResponse((other as Map).cast<Object?, Object?>()),
      throwsA(isA<ProxyExecuteException>()),
    );
  });

  test('requestState returns the live snapshot and marks the window open',
      () async {
    container = makeContainer(_connected);
    expect(container.read(historyWindowBridgeProvider), isFalse);

    final reply = await deliverHubCall('requestState', null);
    final payload = ConnectionEventPayload.decode(
      (reply as Map).cast<Object?, Object?>(),
    );
    expect(payload.phase, 'connected');
    expect(payload.repoPath, '/srv/repo');
    expect(payload.connectionLabel, 'Prod');
    expect(container.read(historyWindowBridgeProvider), isTrue);
  });

  test('forwarded undo records land in the real journal', () async {
    container = makeContainer(_connected);
    final record = UndoRecord(
      repoPath: '/srv/repo',
      kind: UndoOpKind.commit,
      description: 'Commit',
      preHead: 'a' * 40,
      preRef: 'main',
      postHead: 'b' * 40,
      postRef: 'main',
    );
    await deliverHubCall('undoRecord', record.toJson());
    final journaled = container
        .read(undoJournalProvider.notifier)
        .peek('/srv/repo');
    expect(journaled, isNotNull);
    expect(journaled!.description, 'Commit');
    expect(journaled.postHead, 'b' * 40);

    // Version skew: an unknown kind is dropped, never guessed at.
    final skewed = record.toJson()..['kind'] = 'teleport';
    await deliverHubCall('undoRecord', skewed);
    expect(
      container.read(undoJournalProvider)['/srv/repo'],
      hasLength(1),
    );
  });

  test('mutationPerformed marks the own-mutation tracker', () async {
    container = makeContainer(_connected);
    await deliverHubCall('mutationPerformed', {'repoPath': '/srv/repo'});
    expect(
      container
          .read(ownMutationTrackerProvider)
          .isRecent('/srv/repo', DateTime.now(), const Duration(seconds: 3)),
      isTrue,
    );
  });

  test('openRecovery shows the main-window Recovery sheet', () async {
    container = makeContainer(_connected);
    expect(container.read(recoveryVisibleProvider), isFalse);
    await deliverHubCall('openRecovery', null);
    expect(container.read(recoveryVisibleProvider), isTrue);
  });

  test('while open, connection changes are pushed; disconnect also closes',
      () async {
    container = makeContainer(_connected);
    await deliverHubCall('requestState', null); // window is open

    stub.set(_connected.copyWith(repoPath: '/srv/other'));
    await container.pump();
    final change = hubCalls.singleWhere(
      (c) => c.method == 'connectionChanged',
    );
    expect(
      ConnectionEventPayload.decode(
        (change.arguments as Map).cast<Object?, Object?>(),
      ).repoPath,
      '/srv/other',
    );

    hubCalls.clear();
    stub.set(const ConnectionState()); // disconnected
    await container.pump();
    expect(hubCalls.map((c) => c.method), contains('connectionChanged'));
    expect(
      controlCalls.map((c) => c.method),
      contains('closeHistoryWindow'),
      reason: 'the window follows the session',
    );
  });

  test('historyWindowClosed flips the open flag off', () async {
    container = makeContainer(_connected);
    await deliverHubCall('requestState', null);
    expect(container.read(historyWindowBridgeProvider), isTrue);

    await deliverControlCall('historyWindowClosed');
    expect(container.read(historyWindowBridgeProvider), isFalse);
  });
}
