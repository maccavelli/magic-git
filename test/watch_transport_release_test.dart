// MADR 0045 amendment 0045.4 (plan deviation (t)). A watcher gives its host
// claims back before the transport they travel over is closed, replaced or torn
// down.
//
// Found on a live host: after a disconnect the watcher's script removed its own
// pid file and lock as its channel closed, and the heartbeat the client owns
// stayed behind, because the client's removal was issued after the transport
// had gone. Everything here happens against a transport that records when it
// closes and a host that records when a heartbeat is removed, in one log.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_arm_settle.dart';
import 'helpers/fake_watcher_handle.dart';

const _repo = '/repo';

/// A transport that records what is done to it.
class _Transport extends SSHClientManager {
  _Transport(this.log);

  final List<String> log;

  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async => log.add('transport replaced');

  @override
  Future<void>? get done => Completer<void>().future;

  @override
  Future<void> disconnect() async => log.add('transport closed');
}

/// A host that arms every watcher and records each heartbeat removal — and,
/// when told to, never answers one.
class _Host extends SSHCommandExecutor {
  _Host(this.log, {this.releaseNeverAnswers = false})
    : super(SSHClientManager());

  final List<String> log;
  final bool releaseNeverAnswers;
  final handles = <FakeWatcherHandle>[];

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
    final joined = gitArgs.join(' ');
    if (joined.contains('rm -f') && joined.contains('.hb')) {
      log.add('release');
      if (releaseNeverAnswers) await Completer<void>().future;
    }
    return const SSHCommandResult(
      exitCode: 0,
      stdout: 'inotifywait\n',
      stderr: '',
    );
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    final handle = FakeWatcherHandle.armed();
    handles.add(handle);
    return handle;
  }
}

/// Validates every repository, so a connect reaches its transport.
class _Git extends GitService {
  _Git(super.executor);

  @override
  Future<void> validateRepoPath(String repoPath) async {}
}

/// A session already in [phase] on the remote host.
class _Session extends ConnectionController {
  _Session(this.phase);

  final ConnectionPhase phase;

  @override
  ConnectionState build() =>
      ConnectionState(phase: phase, host: 'host', repoPath: _repo);
}

ProviderContainer _container(
  List<String> log,
  _Host host, {
  ConnectionPhase phase = ConnectionPhase.connected,
}) => ProviderContainer(
  retry: (_, _) => null,
  overrides: [
    sshClientManagerProvider.overrideWithValue(_Transport(log)),
    gitServiceProvider.overrideWithValue(_Git(host)),
    connectionProvider.overrideWith(() => _Session(phase)),
    remoteWatchServiceProvider.overrideWith(
      (ref) => RemoteWatchService(
        host,
        hostKey: () => 'host',
        streamBudget: () => 8,
        admission: ref.watch(watchAdmissionProvider),
        gitDirOf: conventionalGitDir,
      ),
    ),
  ],
);

void main() {
  test('a disconnect releases each watcher before it closes the transport', () {
    fakeAsync((async) {
      final log = <String>[];
      final host = _Host(log);
      final container = _container(log, host);
      final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
      async.letArmsSettle();
      expect(host.handles, hasLength(1), reason: 'a watcher armed');

      var disconnected = false;
      unawaited(
        container
            .read(connectionProvider.notifier)
            .disconnect()
            .then((_) => disconnected = true),
      );
      async.letArmsSettle();

      expect(disconnected, isTrue);
      expect(
        log,
        ['release', 'transport closed'],
        reason:
            'the heartbeat is the client\'s to remove; issued after the close, '
            'the removal went nowhere and the heartbeat stayed on the host',
      );
      sub.close();
      container.dispose();
    });
  });

  test('a release that never answers holds the close only for its timeout', () {
    fakeAsync((async) {
      final log = <String>[];
      final host = _Host(log, releaseNeverAnswers: true);
      final container = _container(log, host);
      final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
      async.letArmsSettle();

      var disconnected = false;
      unawaited(
        container
            .read(connectionProvider.notifier)
            .disconnect()
            .then((_) => disconnected = true),
      );
      async.elapse(
        WatchTimings.defaultReleaseTimeout - const Duration(seconds: 1),
      );
      expect(log, ['release'], reason: 'the release is still being waited for');

      async.elapse(const Duration(seconds: 2));
      expect(
        disconnected,
        isTrue,
        reason: 'a host that never answers must not keep the user connected',
      );
      expect(log.last, 'transport closed');
      sub.close();
      container.dispose();
    });
  });

  test('a lost connection closes without waiting on a release', () {
    fakeAsync((async) {
      final log = <String>[];
      final host = _Host(log, releaseNeverAnswers: true);
      final container = _container(log, host, phase: ConnectionPhase.lost);
      final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
      async.letArmsSettle();
      expect(host.handles, hasLength(1));

      var disconnected = false;
      unawaited(
        container
            .read(connectionProvider.notifier)
            .disconnect()
            .then((_) => disconnected = true),
      );
      async.elapse(const Duration(seconds: 1));

      expect(
        disconnected,
        isTrue,
        reason:
            'nothing travels over a lost transport, so nothing is waited for',
      );
      expect(log, contains('transport closed'));
      sub.close();
      container.dispose();
    });
  });

  test(
    'switching hosts releases the watcher before replacing the transport',
    () {
      fakeAsync((async) {
        final log = <String>[];
        final host = _Host(log);
        final container = _container(log, host);
        final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
        async.letArmsSettle();
        expect(host.handles, hasLength(1));

        unawaited(
          container
              .read(connectionProvider.notifier)
              .connect(
                profile: const SSHConnectionProfile(
                  host: 'other',
                  username: 'u',
                ),
                repoPath: '/other',
              ),
        );
        async.letArmsSettle();

        expect(
          log.take(2),
          ['release', 'transport replaced'],
          reason: 'the previous host\'s claims go over the previous transport',
        );
        expect(
          container.read(watchSuspensionProvider),
          isFalse,
          reason: 'the new session watches again',
        );
        sub.close();
        container.dispose();
      });
    },
  );

  test('opening a local repository releases the remote watcher first', () {
    fakeAsync((async) {
      final log = <String>[];
      final host = _Host(log);
      final container = _container(log, host);
      final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
      async.letArmsSettle();
      expect(host.handles, hasLength(1));

      unawaited(
        container.read(connectionProvider.notifier).connectLocal('/local/repo'),
      );
      async.letArmsSettle();

      expect(
        log.take(2),
        ['release', 'transport closed'],
        reason: 'leaving SSH closes its transport, and the watcher goes first',
      );
      sub.close();
      container.dispose();
    });
  });
}
