// The combined status/refs/remotes/pending snapshot and its marker-collision
// fallback: a commit subject (or path) containing the in-band section marker
// makes the combined stdout unsplittable — the service must recover with
// per-section round trips, not wedge the repo's status pane on a thrown
// "malformed output".

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _sep = 'RMGSNAP';

/// A refs line in _refsFormat order: twelve fixed fields, subject, trailing NUL.
String _refLine(String name, String subject) =>
    '${['*', name, 'aaa', '', '', '', '', '', '', '', '', '', subject].join('\u0000')}\u0000';

String _combined({required String refsSection}) => [
  '', // status stdout (clean tree)
  '0',
  refsSection,
  '0',
  'origin\n',
  '0',
  'none',
].join(_sep);

class _QueueExecutor extends SSHCommandExecutor {
  _QueueExecutor() : super(SSHClientManager());
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];

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
    calls.add(gitArgs);
    return results.isNotEmpty
        ? results.removeAt(0)
        : const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  late _QueueExecutor exec;
  late GitService git;

  setUp(() {
    exec = _QueueExecutor();
    git = GitService(exec);
  });

  test('a well-formed combined snapshot is one round trip', () async {
    exec.results.add(
      SSHCommandResult(
        exitCode: 0,
        stdout: _combined(refsSection: '${_refLine('refs/heads/main', 's')}\n'),
        stderr: '',
      ),
    );
    final refs = await git.refs('/repo');
    expect(exec.calls, hasLength(1));
    expect(refs.single.name, 'refs/heads/main');
  });

  test('a marker collision falls back to per-section round trips instead of '
      'throwing', () async {
    // The marker bytes inside a commit subject split the combined stdout into
    // extra sections — unrecoverable by any split.
    exec.results.add(
      SSHCommandResult(
        exitCode: 0,
        stdout: _combined(
          refsSection: '${_refLine('refs/heads/main', 'evil $_sep subject')}\n',
        ),
        stderr: '',
      ),
    );
    // The fallback's own four calls: status, for-each-ref, remote, pending-op.
    exec.results.addAll(const [
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      SSHCommandResult(exitCode: 0, stdout: 'origin\n', stderr: ''),
      SSHCommandResult(exitCode: 0, stdout: 'merge\n', stderr: ''),
    ]);

    final snapshotPending = await git.pendingOp('/repo');
    expect(snapshotPending, PendingOp.merge);
    expect(exec.calls, hasLength(5), reason: 'combined + 4 section fetches');
    expect(exec.calls[1].sublist(0, 2), ['git', '--no-optional-locks']);
    expect(exec.calls[2], contains('for-each-ref'));
    expect(exec.calls[3], ['git', 'remote']);
    expect(exec.calls[4].sublist(0, 2), ['sh', '-c']);
  });

  test('the fallback surfaces a real per-section failure precisely', () async {
    exec.results.add(
      // Truncated combined output (script died early) — also takes the
      // fallback path.
      const SSHCommandResult(exitCode: 1, stdout: 'garbage', stderr: ''),
    );
    exec.results.addAll(const [
      SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository',
      ),
    ]);
    await expectLater(
      () => git.status('/repo'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          'git status failed',
        ),
      ),
    );
  });
}
