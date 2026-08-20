import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

import 'helpers/mock_executor.dart';

const _repo = '/repo';
const _oid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _other = 'cccccccccccccccccccccccccccccccccccccccc';

void main() {
  group('parseBaseDeleteStatusToken', () {
    test('known tokens', () {
      expect(parseBaseDeleteStatusToken('deleted'), BaseDeleteStatus.deleted);
      expect(parseBaseDeleteStatusToken('moved\n'), BaseDeleteStatus.moved);
      expect(
        parseBaseDeleteStatusToken('notMerged'),
        BaseDeleteStatus.notMerged,
      );
      expect(
        parseBaseDeleteStatusToken('checkedOut'),
        BaseDeleteStatus.checkedOut,
      );
      expect(parseBaseDeleteStatusToken('missing'), BaseDeleteStatus.missing);
    });
    test('unknown throws', () {
      expect(() => parseBaseDeleteStatusToken('weird'), throwsFormatException);
    });
  });

  group('GitService.deleteBranchMergedIntoBase', () {
    test('ancestor ok → deleted + undo record with OID', () async {
      final records = <UndoRecord>[];
      final exec = MockExecutor(
        onExecute: (call) {
          final script = call.gitArgs.join(' ');
          expect(script, contains('update-ref'));
          expect(script, contains(_oid));
          expect(script, contains(_base));
          // Simulate _runCaptured framing is complex; call the service
          // through a thinner path by returning a full undo-framed stdout.
          // Instead: the service uses mutationScript via sh -c; MockExecutor
          // returns a framed success with mutation stdout = deleted.
          return _framed(preExtra: _oid, mutOut: 'deleted\n', postExtra: '');
        },
      );
      final git = GitService(exec, onUndoRecord: records.add);
      final result = await git.deleteBranchMergedIntoBase(
        _repo,
        branchName: 'feature',
        expectedBranchOid: _oid,
        baseOid: _base,
      );
      expect(result.status, BaseDeleteStatus.deleted);
      expect(result.deletedOid, _oid);
      expect(records, hasLength(1));
      expect(records.single.kind, UndoOpKind.deleteBranch);
      expect(records.single.refName, 'feature');
      expect(records.single.deletedOid, _oid);
    });

    test('tip moved → moved, no undo', () async {
      final records = <UndoRecord>[];
      final exec = MockExecutor(
        onExecute: (call) =>
            _framed(preExtra: _other, mutOut: 'moved\n', postExtra: _other),
      );
      final git = GitService(exec, onUndoRecord: records.add);
      final result = await git.deleteBranchMergedIntoBase(
        _repo,
        branchName: 'feature',
        expectedBranchOid: _oid,
        baseOid: _base,
      );
      expect(result.status, BaseDeleteStatus.moved);
      expect(records, isEmpty);
    });

    test('not ancestor → notMerged, no undo', () async {
      final records = <UndoRecord>[];
      final exec = MockExecutor(
        onExecute: (call) =>
            _framed(preExtra: _oid, mutOut: 'notMerged\n', postExtra: _oid),
      );
      final git = GitService(exec, onUndoRecord: records.add);
      final result = await git.deleteBranchMergedIntoBase(
        _repo,
        branchName: 'feature',
        expectedBranchOid: _oid,
        baseOid: _base,
      );
      expect(result.status, BaseDeleteStatus.notMerged);
      expect(records, isEmpty);
    });

    test('worktree held → checkedOut, no undo', () async {
      final records = <UndoRecord>[];
      final exec = MockExecutor(
        onExecute: (call) =>
            _framed(preExtra: _oid, mutOut: 'checkedOut\n', postExtra: _oid),
      );
      final git = GitService(exec, onUndoRecord: records.add);
      final result = await git.deleteBranchMergedIntoBase(
        _repo,
        branchName: 'feature',
        expectedBranchOid: _oid,
        baseOid: _base,
      );
      expect(result.status, BaseDeleteStatus.checkedOut);
      expect(records, isEmpty);
    });

    test('missing → missing, no undo', () async {
      final records = <UndoRecord>[];
      final exec = MockExecutor(
        onExecute: (call) =>
            _framed(preExtra: '', mutOut: 'missing\n', postExtra: ''),
      );
      final git = GitService(exec, onUndoRecord: records.add);
      final result = await git.deleteBranchMergedIntoBase(
        _repo,
        branchName: 'feature',
        expectedBranchOid: _oid,
        baseOid: _base,
      );
      expect(result.status, BaseDeleteStatus.missing);
      expect(records, isEmpty);
    });

    test('unexpected failure throws', () async {
      final exec = MockExecutor(
        onExecute: (call) =>
            const SSHCommandResult(exitCode: 128, stdout: '', stderr: 'fatal'),
      );
      await expectLater(
        GitService(exec).deleteBranchMergedIntoBase(
          _repo,
          branchName: 'feature',
          expectedBranchOid: _oid,
          baseOid: _base,
        ),
        throwsA(isA<GitException>()),
      );
    });

    test('rejects short OIDs and bad names before exec', () async {
      final exec = MockExecutor();
      final git = GitService(exec);
      await expectLater(
        git.deleteBranchMergedIntoBase(
          _repo,
          branchName: 'feature',
          expectedBranchOid: 'short',
          baseOid: _base,
        ),
        throwsArgumentError,
      );
      await expectLater(
        git.deleteBranchMergedIntoBase(
          _repo,
          branchName: 'bad name',
          expectedBranchOid: _oid,
          baseOid: _base,
        ),
        throwsArgumentError,
      );
      expect(exec.calls, isEmpty);
    });

    test('script never force-deletes', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final s = call.gitArgs.join(' ');
          expect(s, isNot(contains(' branch -D ')));
          expect(s, isNot(contains(' -D ')));
          expect(s, contains('update-ref -d'));
          return _framed(preExtra: _oid, mutOut: 'deleted\n', postExtra: '');
        },
      );
      await GitService(exec).deleteBranchMergedIntoBase(
        _repo,
        branchName: 'feature',
        expectedBranchOid: _oid,
        baseOid: _base,
      );
    });
  });
}

/// Minimal undo-frame matching _runCaptured's 7+n+m field layout for
/// n=1 pre extra and m=1 post extra.
SSHCommandResult _framed({
  required String preExtra,
  required String mutOut,
  required String postExtra,
  int exitCode = 0,
}) {
  // Must match GitService._undoSep.
  const sep = '\u0002RMGUNDO\u0002';
  // Field layout: '' pre preref x0 mutOut post postref y0 ''
  // parts.length == 7 + 1 + 1 = 9
  final stdout =
      '$sep'
      'HEADPRE$sep'
      'main$sep'
      '$preExtra$sep'
      '$mutOut$sep'
      'HEADPOST$sep'
      'main$sep'
      '$postExtra$sep';
  return SSHCommandResult(exitCode: exitCode, stdout: stdout, stderr: '');
}
