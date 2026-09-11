// MADR 0045 F10 and phase 3. A repository's git dir is git's answer, not
// `<repo>/.git` — which is a FILE in a linked worktree, so the host's lock under
// it refused every worktree as though another watcher held it.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/git_dir_resolver.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Answers each command with [respond], recording what was asked.
class _Scripted extends SSHCommandExecutor {
  _Scripted(this.respond) : super(SSHClientManager());

  final SSHCommandResult Function(List<String> gitArgs) respond;
  final calls = <List<String>>[];

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
    return respond(gitArgs);
  }
}

const _worktreeLayout =
    '/srv/feature\n/srv/main/.git/worktrees/feature\n/srv/main/.git\n';

bool _isModern(List<String> args) => args.contains('--path-format=absolute');

void main() {
  test('a linked worktree resolves to its own git dir', () async {
    final exec = _Scripted(
      (_) => const SSHCommandResult(
        exitCode: 0,
        stdout: _worktreeLayout,
        stderr: '',
      ),
    );

    final gitDir = await gitDirResolverFor(exec)('/srv/feature');

    expect(
      gitDir,
      '/srv/main/.git/worktrees/feature',
      reason:
          'the worktree\'s own admin directory — a directory the host can lock '
          'under, where `/srv/feature/.git` is a file',
    );
    expect(exec.calls.single, contains('--git-dir'));
  });

  test('the legacy fallback is used when --path-format is rejected', () async {
    final exec = _Scripted(
      (args) => _isModern(args)
          ? const SSHCommandResult(
              exitCode: 129,
              stdout: '',
              stderr: 'error: unknown option `path-format=absolute\'',
            )
          : const SSHCommandResult(
              exitCode: 0,
              stdout: _worktreeLayout,
              stderr: '',
            ),
    );

    final gitDir = await gitDirResolverFor(exec)('/srv/feature');

    expect(gitDir, '/srv/main/.git/worktrees/feature');
    expect(exec.calls, hasLength(2));
    expect(exec.calls.last.take(2), [
      'sh',
      '-c',
    ], reason: 'git older than 2.31 resolves through the host-side script');
  });

  test('a failed resolution throws', () async {
    final exec = _Scripted(
      (_) => const SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository',
      ),
    );

    await expectLater(
      gitDirResolverFor(exec)('/srv/not-a-repo'),
      throwsA(isA<GitException>()),
      reason:
          'a guessed git dir is exactly the assumption this replaces; failing '
          'loudly lets the arm restart instead of locking the wrong directory',
    );
  });
}
