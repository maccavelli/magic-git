import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

const _repo = '/repo';
const _base = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _one = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _two = 'cccccccccccccccccccccccccccccccccccccccc';
const _sep = '\u001f';

String _row(int ordinal, String oid, int status, String behind, String ahead) =>
    '$ordinal$_sep$oid$_sep$status$_sep$behind$_sep$ahead\u0000';

void main() {
  test(
    'remoteHead distinguishes missing symref from command failure',
    () async {
      final missing = GitService(
        MockExecutor(
          defaultResult: const SSHCommandResult(
            exitCode: 1,
            stdout: '',
            stderr: '',
          ),
        ),
      );
      expect(await missing.remoteHead(_repo, 'origin'), isNull);

      final broken = GitService(
        MockExecutor(
          defaultResult: const SSHCommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'bad repo',
          ),
        ),
      );
      expect(
        () => broken.remoteHead(_repo, 'origin'),
        throwsA(isA<GitException>()),
      );
    },
  );

  test('review rows join by ordinal and preserve duplicate tips', () async {
    final executor = MockExecutor(
      defaultResult: SSHCommandResult(
        exitCode: 0,
        stdout: '${_row(0, _one, 0, '3', '2')}${_row(1, _one, 0, '3', '2')}',
        stderr: '',
      ),
    );
    final result = await GitService(executor).branchReviewSummaries(
      _repo,
      baseOid: _base,
      branches: const [
        (refName: 'refs/heads/one', oid: _one),
        (refName: 'refs/heads/alias', oid: _one),
      ],
    );
    expect(result.summariesByRefName.keys, {
      'refs/heads/one',
      'refs/heads/alias',
    });
    expect(result.summariesByRefName['refs/heads/one']?.aheadOfBase, 2);
    final command = executor.calls.single.gitArgs.join(' ');
    expect(command, isNot(contains('refs/heads/one')));
    expect(command, contains(_one));
  });

  test('per-row failures do not discard successful siblings', () async {
    final executor = MockExecutor(
      defaultResult: SSHCommandResult(
        exitCode: 0,
        stdout: '${_row(0, _one, 0, '1', '0')}${_row(1, _two, 7, '', '')}',
        stderr: '',
      ),
    );
    final result = await GitService(executor).branchReviewSummaries(
      _repo,
      baseOid: _base,
      branches: const [
        (refName: 'refs/heads/merged', oid: _one),
        (refName: 'refs/heads/bad', oid: _two),
      ],
    );
    expect(
      result.summariesByRefName['refs/heads/merged']?.mergedIntoBase,
      isTrue,
    );
    expect(
      result.failuresByRefName['refs/heads/bad']?.reasonCode,
      'revListFailed',
    );
  });

  test('rejects malformed OIDs before executing', () async {
    final executor = MockExecutor();
    final git = GitService(executor);
    await expectLater(
      git.branchReviewSummaries(
        _repo,
        baseOid: 'short',
        branches: const [(refName: 'refs/heads/one', oid: _one)],
      ),
      throwsArgumentError,
    );
    expect(executor.calls, isEmpty);
  });

  test('oid mismatch and missing records become per-row failures', () async {
    final executor = MockExecutor(
      defaultResult: SSHCommandResult(
        exitCode: 0,
        // Row 0 echoes the wrong OID; row 1 is omitted entirely.
        stdout: _row(0, _two, 0, '0', '1'),
        stderr: '',
      ),
    );
    final result = await GitService(executor).branchReviewSummaries(
      _repo,
      baseOid: _base,
      branches: const [
        (refName: 'refs/heads/one', oid: _one),
        (refName: 'refs/heads/two', oid: _two),
      ],
    );
    expect(
      result.failuresByRefName['refs/heads/one']?.reasonCode,
      'oidMismatch',
    );
    expect(
      result.failuresByRefName['refs/heads/two']?.reasonCode,
      'missingRecord',
    );
    expect(result.summariesByRefName, isEmpty);
  });

  test('whole-batch transport failure fails the summary load', () async {
    final executor = MockExecutor(
      onExecute: (call) {
        expect(call.timeout, GitService.branchReviewBatchTimeout);
        throw const SSHCommandTimeout('branch-review timed out');
      },
    );
    await expectLater(
      GitService(executor).branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: const [(refName: 'refs/heads/one', oid: _one)],
      ),
      throwsA(isA<SSHCommandTimeout>()),
    );
  });

  test('refs fingerprint is order-independent but detects a moved tip', () {
    final a = BranchRefsFingerprint(const [
      (refName: 'refs/heads/two', oid: _two),
      (refName: 'refs/heads/one', oid: _one),
    ]);
    final reordered = BranchRefsFingerprint(const [
      (refName: 'refs/heads/one', oid: _one),
      (refName: 'refs/heads/two', oid: _two),
    ]);
    final moved = BranchRefsFingerprint(const [
      (refName: 'refs/heads/one', oid: _two),
      (refName: 'refs/heads/two', oid: _two),
    ]);
    expect(a, reordered);
    expect(a, isNot(moved));
  });
}
