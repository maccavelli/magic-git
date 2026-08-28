// The provisioning connect flow behind "clone/create to a saved SSH connection
// from the landing": beginProvisioning opens a repo-less session that stays in
// ConnectionPhase.connecting, finalizeProvisioned promotes it onto the new repo
// (persisting it and preserving the clone transcript), and abort/supersession/
// transport-drop all resolve cleanly. Mirrors connection_race_test's harness.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';

/// A manager whose connect() blocks until the test releases a gate.
class _GatedManager extends SSHClientManager {
  final List<Completer<void>> gates = [];
  Completer<void> doneCompleter = Completer<void>();
  int disconnects = 0;

  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) {
    doneCompleter = Completer<void>();
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<void>? get done => doneCompleter.future;

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

/// Records argv so forge-login memoization can be asserted; returns `true\n`
/// so validateRepoPath and the env probe are satisfied. A flag lets a login be
/// forced to fail to exercise the memo eviction.
class _RecordingExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  bool failNextLogin = false;

  _RecordingExecutor() : super(SSHClientManager());

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
    calls.add(gitArgs);
    final isLogin =
        gitArgs.length >= 3 && gitArgs[1] == 'auth' && gitArgs[2] == 'login';
    if (isLogin && failNextLogin) {
      failNextLogin = false;
      return const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'nope');
    }
    return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
  }

  int loginCallsFor(String cli) => calls
      .where((c) => c.first == cli && c.length >= 3 && c[1] == 'auth')
      .length;
}

/// A store that yields fixed secrets and records updateMetadata/touch.
class _FakeStore extends ConnectionStore {
  _FakeStore({this.ghToken});
  final String? ghToken;
  final List<SavedConnection> updated = [];
  final List<String> touched = [];

  @override
  Future<String?> secretFor(String id) async => null;
  @override
  Future<String?> gitlabTokenFor(String id) async => null;
  @override
  Future<String?> githubTokenFor(String id) async => ghToken;
  @override
  Future<String?> privateKeyFor(String id) async => null;
  @override
  Future<String?> passphraseFor(String id) async => null;

  @override
  Future<void> updateMetadata(SavedConnection conn) async => updated.add(conn);
  @override
  Future<void> touch(String id, {DateTime? when}) async => touched.add(id);
}

SavedConnection _conn() => const SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/existing',
  repoPaths: ['/existing'],
);

void main() {
  late _GatedManager manager;
  late _RecordingExecutor executor;
  late _FakeStore store;
  late ProviderContainer container;
  late ConnectionController controller;

  ProviderContainer build({String? ghToken}) {
    manager = _GatedManager();
    executor = _RecordingExecutor();
    store = _FakeStore(ghToken: ghToken);
    final c = ProviderContainer(
      overrides: [
        sshClientManagerProvider.overrideWithValue(manager),
        executorProvider.overrideWithValue(executor),
        gitServiceProvider.overrideWithValue(GitService(_RecordingExecutor())),
        connectionStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pump([int n = 20]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Runs beginProvisioning to the point where the SSH connect is gated, then
  /// releases the gate and returns the resolved token.
  Future<int> begin() async {
    final fut = controller.beginProvisioning(_conn());
    while (manager.gates.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    manager.gates.last.complete();
    final token = await fut;
    expect(token, isNotNull, reason: 'provisioning should have succeeded');
    return token!;
  }

  ConnectionState state() => container.read(connectionProvider);

  test(
    'begin keeps the session in connecting with host/label, no repo',
    () async {
      container = build();
      controller = container.read(connectionProvider.notifier);

      final fut = controller.beginProvisioning(_conn());
      while (manager.gates.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(state().phase, ConnectionPhase.connecting);
      expect(state().host, 'h');
      expect(state().connectionLabel, 'Prod');
      expect(state().repoPath, isNull);

      manager.gates.last.complete();
      expect(await fut, isNotNull);
      // Still provisioning after the env probe — not yet "connected".
      expect(state().phase, ConnectionPhase.connecting);
      expect(state().repoPath, isNull);
    },
  );

  test(
    'finalize promotes to connected, persists the repo, keeps the log',
    () async {
      container = build();
      controller = container.read(connectionProvider.notifier);
      final token = await begin();

      // Simulate the clone transcript landing in the output log.
      container
          .read(outputLogProvider.notifier)
          .logResult(
            'gh repo clone mac/x',
            const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
          );
      final linesBefore = container.read(outputLogProvider).lines.length;

      final ok = await controller.finalizeProvisioned(
        token: token,
        conn: _conn(),
        repoPath: '/existing/newrepo',
      );
      expect(ok, isTrue);
      expect(state().phase, ConnectionPhase.connected);
      expect(state().repoPath, '/existing/newrepo');
      expect(state().repoPaths, contains('/existing/newrepo'));

      expect(store.updated.single.allRepoPaths, contains('/existing/newrepo'));
      expect(store.touched, contains('c1'));
      expect(
        container.read(outputLogProvider).lines.length,
        linesBefore,
        reason: 'the clone transcript must survive finalize',
      );
    },
  );

  test('finalize with fsmonitor persists it into the connection', () async {
    container = build();
    controller = container.read(connectionProvider.notifier);
    final token = await begin();

    await controller.finalizeProvisioned(
      token: token,
      conn: _conn(),
      repoPath: '/existing/newrepo',
      enableFsmonitor: true,
    );
    expect(store.updated.single.fsmonitorPaths, contains('/existing/newrepo'));
  });

  test(
    'a disconnect mid-provision makes finalize a no-op that writes nothing',
    () async {
      container = build();
      controller = container.read(connectionProvider.notifier);
      final token = await begin();

      await controller.disconnect();
      expect(state().phase, ConnectionPhase.disconnected);

      final ok = await controller.finalizeProvisioned(
        token: token,
        conn: _conn(),
        repoPath: '/existing/newrepo',
      );
      expect(ok, isFalse, reason: 'superseded token');
      expect(state().phase, ConnectionPhase.disconnected);
      expect(
        store.updated,
        isEmpty,
        reason: 'nothing persisted after supersede',
      );
    },
  );

  test('abortProvisioning tears the session down to disconnected', () async {
    container = build();
    controller = container.read(connectionProvider.notifier);
    final token = await begin();

    await controller.abortProvisioning(token);
    expect(state().phase, ConnectionPhase.disconnected);
    expect(manager.disconnects, 1);

    // A stale abort (superseded token) does nothing further.
    await controller.abortProvisioning(token);
    expect(manager.disconnects, 1);
  });

  test('a transport drop during provisioning does NOT enter lost', () async {
    container = build();
    controller = container.read(connectionProvider.notifier);
    await begin();
    expect(state().phase, ConnectionPhase.connecting);

    manager.doneCompleter.complete(); // transport drops mid-provision
    await pump();
    expect(
      state().phase,
      ConnectionPhase.connecting,
      reason: 'provisioning has no drop-watcher; must not auto-reconnect',
    );
  });

  test(
    'ensureForgeHostLogin logs in once per (forge, host), retries on failure',
    () async {
      container = build(ghToken: 'ghp_tok');
      controller = container.read(connectionProvider.notifier);
      await begin();

      await controller.ensureForgeHostLogin(Forge.github, 'github.com');
      await controller.ensureForgeHostLogin(Forge.github, 'github.com');
      expect(executor.loginCallsFor('gh'), 1, reason: 'memoized per host');

      // A different host is a distinct memo entry.
      await controller.ensureForgeHostLogin(Forge.github, 'ghe.corp');
      expect(executor.loginCallsFor('gh'), 2);

      // A failed login evicts its memo so the next call retries rather than
      // replaying the cached failure.
      executor.failNextLogin = true;
      await expectLater(
        controller.ensureForgeHostLogin(Forge.github, 'fail.host'),
        throwsA(anything),
      );
      final afterFail = executor.loginCallsFor('gh');
      await controller.ensureForgeHostLogin(Forge.github, 'fail.host');
      expect(
        executor.loginCallsFor('gh'),
        afterFail + 1,
        reason: 'a failed login must be retryable',
      );
    },
  );

  test('ensureForgeHostLogin without a token is a no-op', () async {
    container = build(); // no gh token
    controller = container.read(connectionProvider.notifier);
    await begin();
    await controller.ensureForgeHostLogin(Forge.github, 'github.com');
    expect(executor.loginCallsFor('gh'), 0);
  });
}
