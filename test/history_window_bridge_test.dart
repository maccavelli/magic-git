// The main-isolate end of the native History window: gated open, execute
// serving (success + typed errors), undo-record absorption into the real
// journal, mutation-driven refresh marks, forwarded undo execution, and
// close-on-disconnect.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/history_window_bridge.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/undo/undo_journal.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// When set, [throwNext] only fires for a command whose argv contains this
  /// marker — lets a test target the undo script while unrelated background
  /// fetches (e.g. the pending-op probe) keep succeeding.
  String? throwOnlyIfContains;

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
    final marker = throwOnlyIfContains;
    if (error != null &&
        (marker == null || gitArgs.join(' ').contains(marker))) {
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
    // debugLog is diagnostic chatter for the unified log — not behavior.
    expect(
      controlCalls.map((c) => c.method).where((m) => m != 'debugLog'),
      ['openHistoryWindow'],
    );
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

  test('performUndo runs the journal-top undo and reports the outcome',
      () async {
    container = makeContainer(_connected);

    // Nothing journaled yet — the reply says so instead of guessing.
    expect(
      await deliverHubCall('performUndo', {
        'repoPath': '/srv/repo',
        'force': false,
      }),
      {'status': 'nothingToUndo'},
    );

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

    final reply = await deliverHubCall('performUndo', {
      'repoPath': '/srv/repo',
      'force': false,
    });
    expect((reply as Map)['status'], 'done');
    expect(reply['description'], 'Commit');
    expect(executor.calls, isNotEmpty, reason: 'undo script actually ran');
    expect(
      container.read(undoJournalProvider.notifier).peek('/srv/repo'),
      isNull,
      reason: 'the executed record was popped',
    );
  });

  test('performUndo reports a non-git failure as data, never a throw',
      () async {
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

    // Target the throw at the undo script itself (its argv references the
    // record's preHead) — the pending-op probe's fetch must keep succeeding.
    executor.throwOnlyIfContains = 'a' * 40;
    executor.throwNext = StateError('executor exploded');
    final reply = await deliverHubCall('performUndo', {
      'repoPath': '/srv/repo',
      'force': false,
    });
    expect((reply as Map)['status'], 'error');
    expect(reply['message'], contains('executor exploded'));
  });

  test('forwardTick and invalidateAll reach the hub only while open',
      () async {
    container = makeContainer(_connected);
    final notifier = container.read(historyWindowBridgeProvider.notifier);
    final event = RepoWatchEvent(
      at: DateTime.fromMillisecondsSinceEpoch(1234567),
      mode: WatchMode.eventDriven,
    );

    // Closed: both are no-ops.
    notifier.forwardTick('/srv/repo', event);
    notifier.invalidateAllInHistory('/srv/repo');
    expect(hubCalls, isEmpty);

    await deliverHubCall('requestState', null); // window is open
    notifier.forwardTick('/srv/repo', event);
    notifier.invalidateAllInHistory('/srv/repo');

    final tick = hubCalls.singleWhere((c) => c.method == 'repoTick');
    expect((tick.arguments as Map)['repoPath'], '/srv/repo');
    expect((tick.arguments as Map)['mode'], 'eventDriven');
    expect((tick.arguments as Map)['atMs'], 1234567);
    expect(
      hubCalls.map((c) => c.method),
      contains('invalidateAll'),
    );
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

  test('settingsChanged from the History isolate reloads settings from disk',
      () async {
    container = makeContainer(_connected);
    expect(container.read(appSettingsProvider).historyZoom, 1.0);

    // The History isolate's zoom gestures persisted a new factor; its hub
    // event must make this isolate re-read its SharedPreferences cache.
    SharedPreferences.setMockInitialValues({'historyZoom': 1.4});
    await deliverHubCall('settingsChanged', null);
    expect(container.read(appSettingsProvider).historyZoom, 1.4);
  });

  test('historyWindowClosed flips the open flag off', () async {
    container = makeContainer(_connected);
    await deliverHubCall('requestState', null);
    expect(container.read(historyWindowBridgeProvider), isTrue);

    await deliverControlCall('historyWindowClosed');
    expect(container.read(historyWindowBridgeProvider), isFalse);
  });
}
