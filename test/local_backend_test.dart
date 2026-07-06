// Two linchpins of the local-filesystem backend that had no coverage:
//  1. activeExecutorProvider routing — a regression in its backend switch sends
//     every local command to the dead SSH executor (or vice-versa).
//  2. connectLocal's error path — pointing at a non-git folder must land in
//     `error` while KEEPING backend == local (a reset to ssh would make the
//     error card try to reconnect over SSH), with a message set.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A ConnectionController stuck at a fixed state, so a test can pin `backend`
/// without running a real connect.
class _StubConnection extends ConnectionController {
  final ConnectionState _state;
  _StubConnection(this._state);
  @override
  ConnectionState build() => _state;
}

class _NoopSsh extends SSHCommandExecutor {
  _NoopSsh() : super(SSHClientManager());
}

/// Fails validateRepoPath the way a non-git folder does.
class _NotARepoGit extends GitService {
  _NotARepoGit() : super(_NoopSsh());
  @override
  Future<void> validateRepoPath(String repoPath) async {
    throw const GitException(
      'not a git repository: /x',
      SSHCommandResult(exitCode: 128, stdout: '', stderr: 'fatal: not a repo'),
    );
  }
}

void main() {
  group('activeExecutorProvider routing', () {
    test('a local backend routes to the local executor', () {
      final local = LocalCommandExecutor();
      final ssh = _NoopSsh();
      final container = ProviderContainer(
        overrides: [
          localExecutorProvider.overrideWithValue(local),
          executorProvider.overrideWithValue(ssh),
          connectionProvider.overrideWith(
            () => _StubConnection(
              const ConnectionState(
                phase: ConnectionPhase.connected,
                backend: ConnectionBackend.local,
                repoPath: '/repo',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(activeExecutorProvider), same(local));
    });

    test('an ssh backend routes to the SSH executor', () {
      final local = LocalCommandExecutor();
      final ssh = _NoopSsh();
      final container = ProviderContainer(
        overrides: [
          localExecutorProvider.overrideWithValue(local),
          executorProvider.overrideWithValue(ssh),
          connectionProvider.overrideWith(
            () => _StubConnection(
              const ConnectionState(
                phase: ConnectionPhase.connected,
                repoPath: '/repo',
                host: 'h',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(activeExecutorProvider), same(ssh));
    });
  });

  group('connectLocal error path', () {
    test('a non-git folder lands in error, backend stays local', () async {
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_NotARepoGit()),
          localExecutorProvider.overrideWithValue(LocalCommandExecutor()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionProvider.notifier)
          .connectLocal('/not/a/repo');

      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.error);
      expect(
        state.backend,
        ConnectionBackend.local,
        reason: 'the error card must not fall back to the SSH backend',
      );
      expect(state.error, isNotNull);
      expect(state.repoPath, '/not/a/repo');
    });
  });
}
