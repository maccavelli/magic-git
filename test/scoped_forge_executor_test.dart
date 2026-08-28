// ScopedCommandExecutor injects a scoped/dotfiles repo's GIT_DIR/GIT_WORK_TREE
// overlay into every forge command, keyed by repoPath — the plumbing that
// gives GlabService/GhService (which carry no scope registry) the same scoping
// GitService has, without threading the overlay through their many call sites.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/scoped_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records the [extraEnv] of the last execute/executeStream call.
class _RecordingExecutor implements CommandExecutor {
  Map<String, String>? lastEnv;
  bool lastEnvWasPassed = false;

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
    lastEnv = extraEnv;
    lastEnvWasPassed = true;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) {
    lastEnv = extraEnv;
    lastEnvWasPassed = true;
    throw UnimplementedError();
  }

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {}
  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}
  @override
  String? resolvedBinaryPath(String name) => null;
  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}
  @override
  void resetEnvironment() {}
}

void main() {
  test('a scoped repo gets its GIT_DIR/GIT_WORK_TREE injected', () async {
    final inner = _RecordingExecutor();
    final scoped = ScopedCommandExecutor(
      inner,
      (repoPath) => repoPath == '/home/me'
          ? {'GIT_DIR': '/home/me/.home.git', 'GIT_WORK_TREE': '/home/me'}
          : null,
    );

    await scoped.execute(repoPath: '/home/me', gitArgs: ['glab', 'mr', 'list']);
    expect(inner.lastEnv, {
      'GIT_DIR': '/home/me/.home.git',
      'GIT_WORK_TREE': '/home/me',
    });
  });

  test('an unscoped repo passes extraEnv through untouched', () async {
    final inner = _RecordingExecutor();
    final scoped = ScopedCommandExecutor(inner, (_) => null);

    await scoped.execute(
      repoPath: '/srv/proj',
      gitArgs: ['glab', 'mr', 'list'],
      extraEnv: {'GITLAB_HOST': 'gitlab.example.com'},
    );
    expect(inner.lastEnv, {'GITLAB_HOST': 'gitlab.example.com'});

    await scoped.execute(repoPath: '/srv/proj', gitArgs: ['gh', 'pr', 'list']);
    expect(inner.lastEnv, isNull);
  });

  test(
    'scope and a host env merge; the caller\'s keys win on conflict',
    () async {
      final inner = _RecordingExecutor();
      final scoped = ScopedCommandExecutor(
        inner,
        (_) => {'GIT_DIR': '/g', 'GIT_WORK_TREE': '/w'},
      );

      await scoped.execute(
        repoPath: '/w',
        gitArgs: ['glab', 'api', 'x'],
        extraEnv: {'GLAB_HOST': 'h', 'GIT_DIR': '/override'},
      );
      expect(inner.lastEnv, {
        'GIT_WORK_TREE': '/w',
        'GLAB_HOST': 'h',
        'GIT_DIR': '/override', // caller's extraEnv wins the merge
      });
    },
  );
}
