// End-to-end host-key verification through ConnectionController: trust on
// first use, silent success on a matching key, and — for anything else — a
// paused `hostKeyPrompt` that only resolves via an explicit
// acceptHostKeyChange()/rejectHostKeyChange() call, never automatically.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/known_hosts_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mimics dartssh2's real contract: calls the supplied `onVerifyHostKey` with
/// a controllable key, and — like the real transport does on rejection —
/// throws instead of ever completing when it returns false.
class _VerifyingManager extends SSHClientManager {
  String keyType = 'ssh-ed25519';
  List<int> fingerprintBytes = utf8.encode('SHA256:AAAAAAAAAAAAAAAAAAAA');
  Completer<void> _done = Completer<void>();

  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {
    if (onVerifyHostKey != null) {
      final accepted = await onVerifyHostKey(
        keyType,
        Uint8List.fromList(fingerprintBytes),
      );
      if (!accepted) {
        throw Exception('Hostkey verification failed');
      }
    }
    _done = Completer<void>();
  }

  @override
  Future<void>? get done => _done.future;

  @override
  Future<void> disconnect() async {}

  /// Simulates the transport dropping, triggering auto-reconnect.
  void drop() => _done.complete();
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

void main() {
  const profile = SSHConnectionProfile(host: 'h', port: 22, username: 'u');

  ProviderContainer containerWith(_VerifyingManager manager) {
    SharedPreferences.setMockInitialValues({});
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
    'trust on first use: an unknown host is remembered and connects silently',
    () async {
      final manager = _VerifyingManager();
      final container = containerWith(manager);
      final controller = container.read(connectionProvider.notifier);

      await controller.connect(profile: profile, repoPath: '/repo');

      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.hostKeyPrompt, isNull);

      final stored = await container.read(knownHostsStoreProvider).lookup('h', 22);
      expect(stored!.keyType, 'ssh-ed25519');
      expect(stored.fingerprint, 'SHA256:AAAAAAAAAAAAAAAAAAAA');
    },
  );

  test(
    'a key matching what was already trusted connects silently, no prompt',
    () async {
      final manager = _VerifyingManager();
      final container = containerWith(manager);
      await container.read(knownHostsStoreProvider).remember(
        'h',
        22,
        const KnownHostEntry(
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:AAAAAAAAAAAAAAAAAAAA',
        ),
      );
      final controller = container.read(connectionProvider.notifier);

      await controller.connect(profile: profile, repoPath: '/repo');

      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.hostKeyPrompt, isNull);
    },
  );

  test(
    'a changed key pauses on a prompt; acceptHostKeyChange lets the '
    'connection proceed and remembers the new key',
    () async {
      final manager = _VerifyingManager()
        ..keyType = 'ssh-ed25519'
        ..fingerprintBytes = utf8.encode('SHA256:NEWNEWNEWNEWNEWNEWNE');
      final container = containerWith(manager);
      await container.read(knownHostsStoreProvider).remember(
        'h',
        22,
        const KnownHostEntry(
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:OLDOLDOLDOLDOLDOLDOL',
        ),
      );
      final controller = container.read(connectionProvider.notifier);

      final connecting = controller.connect(profile: profile, repoPath: '/repo');
      await Future<void>.delayed(Duration.zero); // let the prompt land

      final prompt = container.read(connectionProvider).hostKeyPrompt;
      expect(prompt, isNotNull);
      expect(prompt!.previousFingerprint, 'SHA256:OLDOLDOLDOLDOLDOLDOL');
      expect(prompt.newFingerprint, 'SHA256:NEWNEWNEWNEWNEWNEWNE');
      // Still paused — connect() must not resolve on its own.
      expect(container.read(connectionProvider).phase, ConnectionPhase.connecting);

      controller.acceptHostKeyChange();
      await connecting;

      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.hostKeyPrompt, isNull);
      final stored = await container.read(knownHostsStoreProvider).lookup('h', 22);
      expect(stored!.fingerprint, 'SHA256:NEWNEWNEWNEWNEWNEWNE');
    },
  );

  test(
    'a changed key pauses on a prompt; rejectHostKeyChange cancels cleanly '
    'and leaves the old trusted key untouched',
    () async {
      final manager = _VerifyingManager()
        ..keyType = 'ssh-ed25519'
        ..fingerprintBytes = utf8.encode('SHA256:NEWNEWNEWNEWNEWNEWNE');
      final container = containerWith(manager);
      await container.read(knownHostsStoreProvider).remember(
        'h',
        22,
        const KnownHostEntry(
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:OLDOLDOLDOLDOLDOLDOL',
        ),
      );
      final controller = container.read(connectionProvider.notifier);

      final connecting = controller.connect(profile: profile, repoPath: '/repo');
      await Future<void>.delayed(Duration.zero);
      expect(container.read(connectionProvider).hostKeyPrompt, isNotNull);

      controller.rejectHostKeyChange();
      await connecting;

      final state = container.read(connectionProvider);
      // A clean, quiet cancellation — not a scary generic connection error.
      expect(state.phase, ConnectionPhase.disconnected);
      expect(state.error, isNull);
      expect(state.hostKeyPrompt, isNull);

      final stored = await container.read(knownHostsStoreProvider).lookup('h', 22);
      expect(
        stored!.fingerprint,
        'SHA256:OLDOLDOLDOLDOLDOLDOL',
        reason: 'declining the new key must not overwrite the trusted one',
      );
    },
  );

  test(
    'a host-key mismatch during an auto-reconnect attempt pauses the retry '
    'loop instead of retrying forever',
    () {
      fakeAsync((async) {
        final manager = _VerifyingManager();
        final container = containerWith(manager);
        final controller = container.read(connectionProvider.notifier);

        // Initial connect succeeds and trusts the key via TOFU.
        controller.connect(profile: profile, repoPath: '/repo');
        async.flushMicrotasks();
        expect(
          container.read(connectionProvider).phase,
          ConnectionPhase.connected,
        );

        // The remote's key changes, then the transport drops.
        manager.fingerprintBytes = utf8.encode('SHA256:CHANGEDCHANGEDCHANG');
        manager.drop();
        async.flushMicrotasks();
        expect(container.read(connectionProvider).phase, ConnectionPhase.lost);

        // Past the first backoff, auto-reconnect fires and hits the mismatch.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        final prompt = container.read(connectionProvider).hostKeyPrompt;
        expect(prompt, isNotNull);

        // The loop must not queue another retry while paused on the prompt —
        // elapsing well past every backoff window changes nothing.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(container.read(connectionProvider).hostKeyPrompt, same(prompt));

        controller.rejectHostKeyChange();
        async.flushMicrotasks();
        final state = container.read(connectionProvider);
        expect(state.phase, ConnectionPhase.disconnected);
        expect(state.hostKeyPrompt, isNull);

        // And it stays disconnected — no further retry after a deliberate
        // cancel.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(
          container.read(connectionProvider).phase,
          ConnectionPhase.disconnected,
        );
      });
    },
  );
}
