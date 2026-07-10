// Auto-reconnect after an unexpected drop: the controller transitions to
// `lost`, retries with backoff, and reconnects — while a user Stop / disconnect
// cancels the loop. Uses a fake SSHClientManager so no real socket is opened.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeManager extends SSHClientManager {
  Completer<void> _done = Completer<void>();
  int connects = 0;
  bool failNext = false;

  /// When set, `connect()` pauses here before finishing — lets a test land a
  /// concurrent action (e.g. `disconnect()`) exactly while a reconnect attempt
  /// is still in flight, rather than only before or after it.
  Completer<void>? gate;

  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {
    connects++;
    if (gate != null) {
      await gate!.future;
    }
    if (failNext) {
      failNext = false;
      throw Exception('reconnect failed');
    }
    _done = Completer<void>(); // fresh transport lifetime for this connection
  }

  @override
  Future<void>? get done => _done.future;

  @override
  Future<void> disconnect() async => _drop();

  /// Simulate the transport closing cleanly.
  void drop() => _drop();

  /// Simulate an abrupt network loss where `done` completes with an error.
  void dropWithError() {
    if (!_done.isCompleted) _done.completeError(Exception('network lost'));
  }

  void _drop() {
    if (!_done.isCompleted) _done.complete();
  }
}

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  @override
  Future<void> validateRepoPath(String repoPath) async {}
}

ProviderContainer _container(_FakeManager mgr) {
  final c = ProviderContainer(
    overrides: [
      sshClientManagerProvider.overrideWithValue(mgr),
      gitServiceProvider.overrideWithValue(_FakeGit()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

const _profile = SSHConnectionProfile(host: 'h', username: 'u');

Future<void> _connect(ProviderContainer c) =>
    c.read(connectionProvider.notifier).connect(profile: _profile, repoPath: '/r');

void main() {
  test('a drop transitions to lost then auto-reconnects', () async {
    final mgr = _FakeManager();
    final c = _container(mgr);
    await _connect(c);
    expect(c.read(connectionProvider).isConnected, isTrue);
    expect(mgr.connects, 1);

    mgr.drop();
    await Future<void>.delayed(Duration.zero); // flush the done handler
    expect(c.read(connectionProvider).isLost, isTrue);
    expect(c.read(connectionProvider).reconnectAttempt, 1);

    // First backoff is 1s; give it headroom.
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(mgr.connects, 2, reason: 'should have retried the connection');
    expect(c.read(connectionProvider).isConnected, isTrue);
    expect(c.read(connectionProvider).reconnectAttempt, 0);
  });

  test('stopReconnect cancels the loop before it retries', () async {
    final mgr = _FakeManager();
    final c = _container(mgr);
    await _connect(c);

    mgr.drop();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(connectionProvider).isLost, isTrue);

    c.read(connectionProvider.notifier).stopReconnect();
    expect(c.read(connectionProvider).reconnectAttempt, 0);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(mgr.connects, 1, reason: 'stop must prevent the retry');
    expect(c.read(connectionProvider).isLost, isTrue);
  });

  test('an error-completing transport close still auto-reconnects', () async {
    final mgr = _FakeManager();
    final c = _container(mgr);
    await _connect(c);

    mgr.dropWithError(); // abrupt loss: `done` completes with an error
    await Future<void>.delayed(Duration.zero);
    expect(c.read(connectionProvider).isLost, isTrue);
    expect(c.read(connectionProvider).reconnecting, isTrue);
    expect(c.read(connectionProvider).reconnectAttempt, 1);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(mgr.connects, 2, reason: 'an errored drop must still retry');
    expect(c.read(connectionProvider).isConnected, isTrue);
    expect(c.read(connectionProvider).reconnecting, isFalse);
  });

  test('cancel during reconnect returns to the disconnected state', () async {
    final mgr = _FakeManager();
    final c = _container(mgr);
    await _connect(c);

    mgr.drop();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(connectionProvider).reconnecting, isTrue);

    await c.read(connectionProvider.notifier).disconnect();
    expect(c.read(connectionProvider).reconnecting, isFalse);
    expect(c.read(connectionProvider).phase, ConnectionPhase.disconnected);

    // The retry loop must be cancelled — no further connect attempts.
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(mgr.connects, 1);
  });

  test(
    'a disconnect racing an in-flight reconnect attempt wins — the loop must '
    'not stomp state back to `lost` behind its back',
    () async {
      final mgr = _FakeManager();
      final c = _container(mgr);
      await _connect(c);

      mgr.drop();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(connectionProvider).isLost, isTrue);

      // Gate the next connect() so it's still in flight when disconnect()
      // lands, instead of resolving instantly like every other fake call in
      // this file.
      mgr.gate = Completer<void>();

      // Let the first backoff (~1s) elapse so _autoReconnect calls
      // reconnect(), which calls connect() — now stuck on the gate.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(mgr.connects, 2, reason: 'the gated reconnect attempt started');

      // Disconnect while that attempt is still stuck mid-flight.
      await c.read(connectionProvider.notifier).disconnect();
      expect(c.read(connectionProvider).phase, ConnectionPhase.disconnected);

      // Release the gate: the stuck connect() now finishes, discovers (via
      // its own attempt-token check) that it was superseded, and returns
      // without writing state — exactly as before this fix. What's being
      // tested is what happens *next*, back in _autoReconnect: it must not
      // force state back to `lost` just because it isn't `lost` already.
      mgr.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(connectionProvider).phase, ConnectionPhase.disconnected);
      expect(c.read(connectionProvider).reconnecting, isFalse);

      // And the loop must actually be dead — no further retries, ever.
      await Future<void>.delayed(const Duration(milliseconds: 3000));
      expect(
        mgr.connects,
        2,
        reason: 'the reconnect loop must not keep going after a disconnect',
      );
    },
  );

  test('a failed retry keeps trying (stays lost, not error)', () async {
    final mgr = _FakeManager();
    final c = _container(mgr);
    await _connect(c); // initial connect succeeds
    mgr.failNext = true; // make the *first retry* fail

    mgr.drop();
    await Future<void>.delayed(Duration.zero);

    // First retry (~1s) fails; second (~2s later) succeeds.
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(mgr.connects, 2);
    expect(c.read(connectionProvider).isLost, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(mgr.connects, 3);
    expect(c.read(connectionProvider).isConnected, isTrue);
  });
}
