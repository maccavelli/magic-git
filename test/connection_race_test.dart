import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A manager whose connect() blocks until the test releases a gate, so we can
/// interleave a disconnect / a second connect while the first is mid-flight.
class _GatedManager extends SSHClientManager {
  final List<Completer<void>> gates = [];
  // A fresh "transport closed" completer per connect, mirroring how a real
  // reconnect yields a brand-new client with its own done future.
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

class _NoopExecutor extends SSHCommandExecutor {
  _NoopExecutor() : super(SSHClientManager());

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
  }) async {
    return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
  }
}

/// Records every `setFsmonitorMany` call (the connect path now applies all
/// opted-in repos in one batched round trip) and, on the first one only,
/// pauses until the test releases [gateFirst] — used to land a disconnect()
/// while the fsmonitor step is still in flight.
class _FsmonitorTrackingGit extends GitService {
  _FsmonitorTrackingGit() : super(_NoopExecutor());
  final List<List<String>> calls = [];
  Completer<void>? gateFirst;

  @override
  Future<void> validateRepoPath(String repoPath) async {}

  @override
  Future<SSHCommandResult> setFsmonitorMany(
    List<String> repoPaths, {
    required bool enabled,
  }) async {
    calls.add(List.of(repoPaths));
    if (calls.length == 1 && gateFirst != null) {
      await gateFirst!.future;
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// A GhService whose token login can be held open by the test (to interleave
/// state assertions / a disconnect while the *background* login is still in
/// flight) and optionally made to fail; also records pullRequests calls so
/// the forge-provider gating can be asserted.
class _GatedGh extends GhService {
  _GatedGh() : super(_NoopExecutor());
  Completer<void>? gate;
  bool fail = false;
  int logins = 0;
  int prCalls = 0;

  @override
  Future<void> loginWithToken(String repoPath, String token) async {
    logins++;
    if (gate != null) await gate!.future;
    if (fail) {
      throw const GhException(
        'gh auth login failed',
        SSHCommandResult(exitCode: 1, stdout: '', stderr: ''),
      );
    }
  }

  @override
  Future<List<PullRequest>> pullRequests(
    String repoPath, {
    int limit = 50,
  }) async {
    prCalls++;
    return const [];
  }
}

void main() {
  const profile = SSHConnectionProfile(host: 'h', username: 'u');

  ProviderContainer containerWith(_GatedManager manager) {
    final container = ProviderContainer(
      overrides: [
        sshClientManagerProvider.overrideWithValue(manager),
        gitServiceProvider.overrideWithValue(GitService(_NoopExecutor())),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'disconnect issued mid-connect wins; the late connect drops its state',
    () async {
      final manager = _GatedManager();
      final container = containerWith(manager);
      final controller = container.read(connectionProvider.notifier);

      final connecting = controller.connect(
        profile: profile,
        repoPath: '/repo',
      );
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.connecting,
      );

      await controller.disconnect();
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.disconnected,
      );

      // The slow connect resolves *after* the disconnect — it must not flip the
      // state back to connected.
      manager.gates.first.complete();
      await connecting;
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.disconnected,
      );
    },
  );

  test('a newer connect supersedes an in-flight one', () async {
    final manager = _GatedManager();
    final container = containerWith(manager);
    final controller = container.read(connectionProvider.notifier);

    final first = controller.connect(profile: profile, repoPath: '/first');
    final second = controller.connect(
      profile: profile,
      repoPath: '/second',
      connectionLabel: 'second',
    );

    // Resolve the first (superseded) connect last to prove it can't win.
    manager.gates[1].complete();
    await second;
    manager.gates[0].complete();
    await first;

    final state = container.read(connectionProvider);
    expect(state.phase, ConnectionPhase.connected);
    expect(state.repoPath, '/second');
  });

  test(
    'a dropped transport moves to lost; reconnect restores connected',
    () async {
      final manager = _GatedManager();
      final container = containerWith(manager);
      final controller = container.read(connectionProvider.notifier);

      final first = controller.connect(profile: profile, repoPath: '/repo');
      manager.gates[0].complete();
      await first;
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.connected,
      );

      // Transport drops.
      manager.doneCompleter.complete();
      await Future<void>.delayed(
        Duration.zero,
      ); // flush the done .then microtask
      expect(container.read(connectionProvider).phase, ConnectionPhase.lost);

      // One-click reconnect re-establishes with the same profile/repo.
      final again = controller.reconnect();
      manager.gates[1].complete();
      await again;
      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.repoPath, '/repo');
    },
  );

  test('a drop auto-reconnects after the backoff, no manual click', () {
    fakeAsync((async) {
      final manager = _GatedManager();
      final container = containerWith(manager);
      final controller = container.read(connectionProvider.notifier);

      controller.connect(profile: profile, repoPath: '/repo');
      manager.gates[0].complete();
      async.flushMicrotasks();
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.connected,
      );

      // Transport drops → auto-reconnect engages (attempt 1) while still `lost`.
      manager.doneCompleter.complete();
      async.flushMicrotasks();
      expect(container.read(connectionProvider).phase, ConnectionPhase.lost);
      expect(container.read(connectionProvider).reconnectAttempt, 1);
      expect(manager.gates.length, 1, reason: 'still waiting out the backoff');

      // Past the first 1s backoff the loop issues a fresh connect on its own.
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(manager.gates.length, 2, reason: 'auto reconnect attempted');

      manager.gates[1].complete();
      async.flushMicrotasks();
      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.repoPath, '/repo');
      expect(state.reconnectAttempt, 0);
    });
  });

  test('stopReconnect aborts the auto-reconnect loop', () {
    fakeAsync((async) {
      final manager = _GatedManager();
      final container = containerWith(manager);
      final controller = container.read(connectionProvider.notifier);

      controller.connect(profile: profile, repoPath: '/repo');
      manager.gates[0].complete();
      async.flushMicrotasks();

      manager.doneCompleter.complete();
      async.flushMicrotasks();
      expect(container.read(connectionProvider).reconnectAttempt, 1);

      // User halts the loop before the first backoff elapses.
      controller.stopReconnect();
      expect(container.read(connectionProvider).reconnectAttempt, 0);

      // Even past every backoff window, no further connect is attempted.
      async.elapse(const Duration(seconds: 60));
      async.flushMicrotasks();
      expect(manager.gates.length, 1, reason: 'loop was superseded');
      expect(container.read(connectionProvider).phase, ConnectionPhase.lost);
      // The MANAGER was superseded too, not just the controller's counter: a
      // reconnect attempt caught mid-handshake would otherwise pass the
      // manager's own generation checks, attach its clients, and run a health
      // monitor against a session the UI says was stopped.
      expect(
        manager.disconnects,
        greaterThanOrEqualTo(1),
        reason: 'stopReconnect must supersede the manager generation',
      );
    });
  });

  test(
    'the connecting phase carries host/label immediately, not just on success',
    () async {
      final manager = _GatedManager();
      final container = containerWith(manager);
      final controller = container.read(connectionProvider.notifier);

      final connecting = controller.connect(
        profile: profile,
        repoPath: '/repo',
        connectionLabel: 'Prod',
      );
      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connecting);
      expect(state.host, 'h');
      expect(state.connectionLabel, 'Prod');
      expect(state.repoPath, '/repo');

      manager.gates.first.complete();
      await connecting;
    },
  );

  test(
    'a failed reconnect attempt keeps the host visible in the lost state',
    () {
      fakeAsync((async) {
        final manager = _GatedManager();
        final container = containerWith(manager);
        final controller = container.read(connectionProvider.notifier);

        controller.connect(
          profile: profile,
          repoPath: '/repo',
          connectionLabel: 'Prod',
        );
        manager.gates[0].complete();
        async.flushMicrotasks();
        expect(
          container.read(connectionProvider).phase,
          ConnectionPhase.connected,
        );

        manager.doneCompleter.complete(); // drop
        async.flushMicrotasks();
        expect(container.read(connectionProvider).phase, ConnectionPhase.lost);
        expect(container.read(connectionProvider).host, 'h');

        // Past the first backoff, auto-reconnect fires — let this attempt fail.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(manager.gates.length, 2);
        manager.gates[1].completeError(Exception('still down'));
        async.flushMicrotasks();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnectionPhase.lost);
        expect(
          state.host,
          'h',
          reason: 'host must survive a failed retry, not just a successful one',
        );
        expect(state.connectionLabel, 'Prod');
      });
    },
  );

  test('a disconnect racing the (batched) fsmonitor step drops the connect '
      'instead of proceeding with a superseded session', () async {
    final manager = _GatedManager();
    final git = _FsmonitorTrackingGit()..gateFirst = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        sshClientManagerProvider.overrideWithValue(manager),
        gitServiceProvider.overrideWithValue(git),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionProvider.notifier);

    final connecting = controller.connect(
      profile: profile,
      repoPath: '/repo',
      fsmonitorPaths: const ['/repo/a', '/repo/b'],
    );
    manager.gates.first.complete(); // let the SSH connect step finish
    await Future<void>.delayed(Duration.zero); // reach the fsmonitor step
    expect(
      git.calls,
      [
        ['/repo/a', '/repo/b'],
      ],
      reason: 'all opted-in repos are applied in ONE batched round trip',
    );

    await controller.disconnect(); // supersedes this connect attempt

    git.gateFirst!.complete(); // release the stuck fsmonitor call
    await connecting;

    expect(git.calls.length, 1, reason: 'no further fsmonitor work');
    expect(
      container.read(connectionProvider).phase,
      ConnectionPhase.disconnected,
      reason: 'the superseded connect must not clobber the disconnect',
    );
  });

  ProviderContainer containerWithGh(_GatedManager manager, _GatedGh gh) {
    final container = ProviderContainer(
      overrides: [
        sshClientManagerProvider.overrideWithValue(manager),
        gitServiceProvider.overrideWithValue(GitService(_NoopExecutor())),
        ghServiceProvider.overrideWithValue(gh),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('connect publishes `connected` without waiting for the forge login; a '
      'failed login surfaces as a warning afterwards', () async {
    final manager = _GatedManager();
    final gh = _GatedGh()
      ..gate = Completer<void>()
      ..fail = true;
    final container = containerWithGh(manager, gh);
    final controller = container.read(connectionProvider.notifier);

    final connecting = controller.connect(
      profile: profile,
      repoPath: '/repo',
      githubToken: 'tok',
    );
    manager.gates.first.complete();
    await connecting;

    // The session is usable while the login is still held open — this is
    // the whole point of moving the login off the connect critical path.
    final state = container.read(connectionProvider);
    expect(state.phase, ConnectionPhase.connected);
    expect(state.warning, isNull);
    expect(gh.logins, 1, reason: 'login started in the background');
    expect(
      container
          .read(outputLogProvider)
          .lines
          .any((l) => l.text.startsWith('connected to h in ')),
      isTrue,
      reason: 'per-stage timing line logged at connected',
    );

    final settled = controller.forgeAuthSettled;
    gh.gate!.complete();
    await settled;
    expect(
      container.read(connectionProvider).warning,
      contains('GitHub token login failed'),
      reason: 'the failure still surfaces, just without blocking connect',
    );
    expect(
      container.read(connectionProvider).phase,
      ConnectionPhase.connected,
      reason: 'a login failure is a warning, never a failed session',
    );
  });

  test('a disconnect during the background login releases forgeAuthSettled and '
      'suppresses the stale warning', () async {
    final manager = _GatedManager();
    final gh = _GatedGh()
      ..gate = Completer<void>()
      ..fail = true;
    final container = containerWithGh(manager, gh);
    final controller = container.read(connectionProvider.notifier);

    // Before any connect the gate is already open — nothing to wait for.
    await controller.forgeAuthSettled;

    final connecting = controller.connect(
      profile: profile,
      repoPath: '/repo',
      githubToken: 'tok',
    );
    manager.gates.first.complete();
    await connecting;
    expect(container.read(connectionProvider).phase, ConnectionPhase.connected);

    await controller.disconnect();
    // disconnect() must release awaiters immediately — no connect will ever
    // complete the departing session's gate.
    await controller.forgeAuthSettled;

    gh.gate!.complete(); // the stale login settles after supersession
    await Future<void>.delayed(Duration.zero);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnectionPhase.disconnected);
    expect(
      state.warning,
      isNull,
      reason: 'a superseded attempt must not write onto the new state',
    );
  });

  test(
    'forge data providers hold their fetch until the login settles',
    () async {
      final manager = _GatedManager();
      final gh = _GatedGh()..gate = Completer<void>();
      final container = containerWithGh(manager, gh);
      final controller = container.read(connectionProvider.notifier);

      final connecting = controller.connect(
        profile: profile,
        repoPath: '/repo',
        githubToken: 'tok',
      );
      manager.gates.first.complete();
      await connecting;

      // A panel visible right at connect starts its fetch immediately…
      final prs = container.read(pullRequestsProvider('/repo').future);
      await Future<void>.delayed(Duration.zero);
      expect(
        gh.prCalls,
        0,
        reason: 'the fetch must wait for the background login, not race it',
      );

      // …and proceeds the moment the login lands.
      gh.gate!.complete();
      expect(await prs, isEmpty);
      expect(gh.prCalls, 1);
    },
  );
}
