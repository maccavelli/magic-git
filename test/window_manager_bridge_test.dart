// The main-isolate registry for native secondary windows: gated open over the
// `magicgit/windows` control channel, dedupe/front, per-window hub serving
// (execute success + typed errors), undo-record absorption into the real
// journal, mutation-driven refresh marks, forwarded undo execution, per-window
// event fan-out (tick/invalidate/connectionChanged), and close-on-disconnect.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/window_manager_bridge.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/pane_layout.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/undo/undo_journal.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';
import 'package:remote_magic_git/core/window/window_kind.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The first window minted in a fresh container always gets id '1'.
const _id = '1';
const _control = MethodChannel(windowControlChannel);
final _hub = MethodChannel(windowHubChannel(_id));
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
    // Activate the bridge (installs the control handler), then wire it to serve
    // from this container for a fixed tab id — the role TabsHost plays in the
    // app. All windows here pin to 'tab-1' → this container.
    c.read(windowManagerBridgeProvider.notifier)
      ..sessionContainerFor = ((_) => c)
      ..activeTabId = (() => 'tab-1');
    return c;
  }

  /// Opens the History window (mints id '1'); its per-window hub handler is now
  /// live, so [deliverHubCall] can reach it.
  Future<void> openHistory() =>
      container.read(windowManagerBridgeProvider.notifier).openHistory();

  /// Simulates the relay delivering a call from the window's isolate and
  /// returns the decoded reply.
  Future<Object?> deliverHubCall(String method, Object? arguments) async {
    Object? decoded;
    await messenger.handlePlatformMessage(
      windowHubChannel(_id),
      _codec.encodeMethodCall(MethodCall(method, arguments)),
      (reply) => decoded = reply == null ? null : _codec.decodeEnvelope(reply),
    );
    return decoded;
  }

  Future<void> deliverControlCall(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      windowControlChannel,
      _codec.encodeMethodCall(MethodCall(method, arguments)),
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
    // Captures the main→window pushes the bridge sends over the hub.
    messenger.setMockMethodCallHandler(_hub, (call) async {
      hubCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_control, null);
    messenger.setMockMethodCallHandler(_hub, null);
  });

  test('openHistory asks Swift for a window only while a repo is active',
      () async {
    container = makeContainer(_connected);
    await openHistory();
    final open = controlCalls.singleWhere((c) => c.method == 'openWindow');
    expect((open.arguments as Map)['kind'], WindowKind.history.name);
    expect((open.arguments as Map)['windowId'], _id);
    expect((open.arguments as Map)['repoPath'], '/srv/repo');
    expect(
      container.read(windowManagerBridgeProvider).map((w) => w.kind),
      [WindowKind.history],
    );

    controlCalls.clear();
    stub.set(const ConnectionState()); // disconnected
    await container.read(windowManagerBridgeProvider.notifier).openHistory();
    expect(controlCalls.map((c) => c.method), isNot(contains('openWindow')));
  });

  test('opening History again fronts the existing window (no duplicate)',
      () async {
    container = makeContainer(_connected);
    await openHistory();
    controlCalls.clear();
    await openHistory();
    // debugLog is diagnostic chatter for the unified log — not behavior.
    expect(
      controlCalls.map((c) => c.method).where((m) => m != 'debugLog'),
      ['frontWindow'],
    );
    expect(
      controlCalls.singleWhere((c) => c.method == 'frontWindow').arguments,
      {'windowId': _id},
    );
    expect(container.read(windowManagerBridgeProvider), hasLength(1));
  });

  test('serves execute calls: success and each typed error as envelopes',
      () async {
    container = makeContainer(_connected);
    await openHistory();
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
    expect(decodeExecuteResponse((ok as Map).cast<Object?, Object?>()).stdout,
        'served');
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

  test('ping answers from the hub alone, whatever the session is doing',
      () async {
    // The child window's liveness probe rests entirely on this. A ping has to
    // mean exactly one thing — "this hub is wired up and reading its channel" —
    // so it must answer without touching a session, an executor or the lane
    // scheduler. If it could queue behind a running command, or fail because the
    // pinned tab had closed, the child would read a LIVE main window as dead and
    // abandon commands that were about to succeed.
    container = makeContainer(_connected);
    await openHistory();

    expect(await deliverHubCall('ping', null), isNull);
    expect(
      executor.calls,
      isEmpty,
      reason: 'a ping must not reach the executor at all',
    );

    // And with no session behind the window at all: `execute` would (rightly)
    // come back RELAY_DOWN here, but the window itself is still very much alive
    // and must not be mistaken for dead.
    container = makeContainer(
      const ConnectionState(phase: ConnectionPhase.disconnected),
    );
    expect(
      await deliverHubCall('ping', null),
      isNull,
      reason: 'liveness is about the hub, not about what it can currently serve',
    );
  });

  test('requestState returns the window\'s pinned snapshot', () async {
    container = makeContainer(_connected);
    await openHistory();
    final reply = await deliverHubCall('requestState', null);
    final payload =
        ConnectionEventPayload.decode((reply as Map).cast<Object?, Object?>());
    expect(payload.phase, 'connected');
    expect(payload.repoPath, '/srv/repo');
    expect(payload.connectionLabel, 'Prod');
  });

  test('forwarded undo records land in the real journal', () async {
    container = makeContainer(_connected);
    await openHistory();
    final record = _record();
    await deliverHubCall('undoRecord', record.toJson());
    final journaled =
        container.read(undoJournalProvider.notifier).peek('/srv/repo');
    expect(journaled, isNotNull);
    expect(journaled!.description, 'Commit');

    // Version skew: an unknown kind is dropped, never guessed at.
    final skewed = record.toJson()..['kind'] = 'teleport';
    await deliverHubCall('undoRecord', skewed);
    expect(container.read(undoJournalProvider)['/srv/repo'], hasLength(1));
  });

  test('a forwarded undo record is flagged window-originated so the main '
      'window skips its redundant toast', () async {
    container = makeContainer(_connected);
    await openHistory();
    await deliverHubCall('undoRecord', _record().toJson());
    final journaled =
        container.read(undoJournalProvider.notifier).peek('/srv/repo');
    expect(journaled, isNotNull);
    expect(
      container.read(historyOriginUndoProvider.notifier).take(journaled!),
      isTrue,
      reason: 'the record was marked window-originated',
    );
    expect(container.read(historyOriginUndoProvider), isEmpty);
    expect(
      container.read(historyOriginUndoProvider.notifier).take(journaled),
      isFalse,
    );
  });

  test('mutationPerformed marks the own-mutation tracker', () async {
    container = makeContainer(_connected);
    await openHistory();
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
    await openHistory();

    expect(
      await deliverHubCall('performUndo', {
        'repoPath': '/srv/repo',
        'force': false,
      }),
      {'status': 'nothingToUndo'},
    );

    await deliverHubCall('undoRecord', _record().toJson());
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
    await openHistory();
    await deliverHubCall('undoRecord', _record().toJson());

    executor.throwOnlyIfContains = 'a' * 40;
    executor.throwNext = StateError('executor exploded');
    final reply = await deliverHubCall('performUndo', {
      'repoPath': '/srv/repo',
      'force': false,
    });
    expect((reply as Map)['status'], 'error');
    expect(reply['message'], contains('executor exploded'));
  });

  test('forwardTick and invalidateAllFor reach the hub only for an open window',
      () async {
    container = makeContainer(_connected);
    final notifier = container.read(windowManagerBridgeProvider.notifier);
    final event = RepoWatchEvent(
      at: DateTime.fromMillisecondsSinceEpoch(1234567),
      mode: WatchMode.eventDriven,
    );

    // No window open: both are no-ops.
    notifier.forwardTick('/srv/repo', event);
    notifier.invalidateAllFor('/srv/repo');
    expect(hubCalls, isEmpty);

    await openHistory();
    notifier.forwardTick('/srv/repo', event);
    notifier.invalidateAllFor('/srv/repo');

    final tick = hubCalls.singleWhere((c) => c.method == 'repoTick');
    expect((tick.arguments as Map)['repoPath'], '/srv/repo');
    expect((tick.arguments as Map)['mode'], 'eventDriven');
    expect((tick.arguments as Map)['atMs'], 1234567);
    expect(hubCalls.map((c) => c.method), contains('invalidateAll'));
  });

  test('while open, connection changes are pushed; disconnect also closes',
      () async {
    container = makeContainer(_connected);
    await openHistory();

    stub.set(_connected.copyWith(repoPath: '/srv/other'));
    await container.pump();
    final change =
        hubCalls.singleWhere((c) => c.method == 'connectionChanged');
    expect(
      ConnectionEventPayload.decode(
        (change.arguments as Map).cast<Object?, Object?>(),
      ).repoPath,
      '/srv/other',
      reason: 'a History window retargets to follow the active repo',
    );

    hubCalls.clear();
    controlCalls.clear();
    stub.set(const ConnectionState()); // disconnected
    await container.pump();
    expect(hubCalls.map((c) => c.method), contains('connectionChanged'));
    expect(
      controlCalls.map((c) => c.method),
      contains('closeWindow'),
      reason: 'the window follows the session',
    );
  });

  test('settingsChanged from a window reloads settings from disk', () async {
    container = makeContainer(_connected);
    await openHistory();
    expect(container.read(appSettingsProvider).historyZoom, 1.0);

    SharedPreferences.setMockInitialValues({'historyZoom': 1.4});
    await deliverHubCall('settingsChanged', null);
    expect(container.read(appSettingsProvider).historyZoom, 1.4);
  });

  test('settingsChanged from a window reloads pane widths from disk', () async {
    container = makeContainer(_connected);
    await openHistory();
    expect(
      container.read(appSettingsProvider).paneWidth(PaneId.historyList),
      420,
      reason: 'spec default before any stored width',
    );

    SharedPreferences.setMockInitialValues({'paneWidth_historyList': 500.0});
    await deliverHubCall('settingsChanged', null);
    expect(
      container.read(appSettingsProvider).paneWidth(PaneId.historyList),
      500,
    );
  });

  test('reloadFromDisk still applies disk state after a local edit in this '
      'isolate', () async {
    SharedPreferences.setMockInitialValues({'historyZoom': 1.0});
    container = makeContainer(_connected);
    await openHistory();
    await container.read(appSettingsProvider.notifier).setHistoryZoom(1.5);
    expect(container.read(appSettingsProvider).historyZoom, 1.5);

    SharedPreferences.setMockInitialValues({'historyZoom': 0.8});
    await deliverHubCall('settingsChanged', null);
    expect(container.read(appSettingsProvider).historyZoom, 0.8);
  });

  test('windowClosed forgets the window', () async {
    container = makeContainer(_connected);
    await openHistory();
    expect(container.read(windowManagerBridgeProvider), hasLength(1));

    await deliverControlCall('windowClosed', {'windowId': _id});
    expect(container.read(windowManagerBridgeProvider), isEmpty);
  });
}

UndoRecord _record() => UndoRecord(
  repoPath: '/srv/repo',
  kind: UndoOpKind.commit,
  description: 'Commit',
  preHead: 'a' * 40,
  preRef: 'main',
  postHead: 'b' * 40,
  postRef: 'main',
);
