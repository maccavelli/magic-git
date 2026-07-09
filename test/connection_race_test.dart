import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
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
      expect(container.read(connectionProvider).phase, ConnectionPhase.connected);

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

  test(
    'a disconnect racing the (batched) fsmonitor step drops the connect '
    'instead of proceeding with a superseded session',
    () async {
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
    },
  );
}
