// A missing `git` (exit 127) must surface as a clear "git not found" message,
// not the misleading "not a git repository" / "<label> failed".

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor(this.result) : super(SSHClientManager());
  final SSHCommandResult result;

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
  }) async => result;
}

void main() {
  const notFound = SSHCommandResult(
    exitCode: 127,
    stdout: '',
    stderr: 'sh: git: command not found',
  );

  test('validateRepoPath maps 127 to a "git not found" message', () async {
    final git = GitService(_FakeExecutor(notFound));
    await expectLater(
      () => git.validateRepoPath('/repo'),
      throwsA(
        isA<GitException>()
            .having((e) => e.message, 'message', contains('git was not found'))
            .having((e) => e.message, 'message', contains('External tools')),
      ),
    );
  });

  test('a 127 on a normal mutation also reports git-not-found', () async {
    final git = GitService(_FakeExecutor(notFound));
    await expectLater(
      () => git.stage('/repo', 'a.dart'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          contains('git was not found'),
        ),
      ),
    );
  });

  test('a non-127 failure keeps its own label', () async {
    const other = SSHCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'pathspec did not match',
    );
    final git = GitService(_FakeExecutor(other));
    await expectLater(
      () => git.stage('/repo', 'a.dart'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          isNot(contains('git was not found')),
        ),
      ),
    );
  });
}
