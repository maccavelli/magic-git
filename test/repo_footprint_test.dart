// GitService.repoFootprint: parses `git count-objects -vH` for the
// dashboard's on-demand Measure action, including the gc heuristic.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  _FakeExecutor() : super(SSHClientManager());

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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    calls.add(gitArgs);
    return next;
  }
}

void main() {
  test('parses count-objects output', () async {
    final exec = _FakeExecutor()
      ..next = const SSHCommandResult(
        exitCode: 0,
        stdout: '''
count: 137
size: 1.20 MiB
in-pack: 84121
packs: 3
size-pack: 2.85 GiB
prune-packable: 0
garbage: 0
size-garbage: 0 bytes
''',
        stderr: '',
      );
    final fp = await GitService(exec).repoFootprint('/srv/repo');
    expect(exec.calls.single, ['git', 'count-objects', '-v', '-H']);
    expect(fp.looseObjects, 137);
    expect(fp.looseSize, '1.20 MiB');
    expect(fp.inPackObjects, 84121);
    expect(fp.packs, 3);
    expect(fp.packSize, '2.85 GiB');
    expect(fp.wouldBenefitFromGc, isFalse);
  });

  test('flags a store that would benefit from gc', () async {
    final exec = _FakeExecutor()
      ..next = const SSHCommandResult(
        exitCode: 0,
        stdout:
            'count: 9000\nsize: 40 MiB\nin-pack: 100\npacks: 1\n'
            'size-pack: 1 MiB\n',
        stderr: '',
      );
    final fp = await GitService(exec).repoFootprint('/srv/repo');
    expect(fp.wouldBenefitFromGc, isTrue);
  });

  test('a failed command throws with the carried result', () async {
    final exec = _FakeExecutor()
      ..next = const SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository',
      );
    await expectLater(
      GitService(exec).repoFootprint('/x'),
      throwsA(isA<GitException>()),
    );
  });
}
