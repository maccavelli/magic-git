// MADR 0039 A1. Base-relative divergence for every local branch in ONE revision
// walk, via `for-each-ref --format='%(ahead-behind:<base>)'` (Git ≥ 2.41),
// instead of one `git rev-list --left-right --count` per branch.
//
// The two primitives disagree about field order, verified against git 2.55.0:
//
//   %(ahead-behind:HEAD~5)                ->  "5 0"    ahead behind, space
//   rev-list --left-right --count A...B   ->  "0\t5"   behind ahead, TAB
//
// The fallback parser reads behind first. Transposing them here would report
// every branch's divergence backwards, plausibly and silently — which is why
// the ordering assertion below is the one the mutation catalogue targets.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/tool_catalog.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

const _repo = '/repo';
const _base = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _oneOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _twoOid = 'cccccccccccccccccccccccccccccccccccccccc';
const _movedOid = 'dddddddddddddddddddddddddddddddddddddddd';
const _sep = '\u001f';

const _branches = [
  (refName: 'refs/heads/one', oid: _oneOid),
  (refName: 'refs/heads/two', oid: _twoOid),
];

/// One `for-each-ref` output row: refname, objectname, then `<ahead> <behind>`.
String _row(String refName, String oid, int ahead, int behind) =>
    '$refName$_sep$oid$_sep$ahead $behind';

MockExecutor _forEachRef(String stdout, {int exitCode = 0}) => MockExecutor(
  defaultResult: SSHCommandResult(
    exitCode: exitCode,
    stdout: stdout,
    stderr: '',
  ),
);

void main() {
  group('version gate', () {
    test('the atom is gated at 2.41', () {
      expect(aheadBehindAtomForVersion('2.40.1'), isFalse);
      expect(aheadBehindAtomForVersion('2.41.0'), isTrue);
      expect(aheadBehindAtomForVersion('2.55.0'), isTrue);
      expect(aheadBehindAtomForVersion('3.0'), isTrue);
      expect(kAheadBehindAtomMinGit, const ToolVersion(2, 41));
    });

    test('an unknown version means "take the slow road", not an error', () {
      // Deliberately unlike `mergePreviewCapabilityForVersion`, which returns
      // null for unknown because it gates a feature with no fallback.
      expect(aheadBehindAtomForVersion(null), isFalse);
      expect(aheadBehindAtomForVersion(''), isFalse);
      expect(aheadBehindAtomForVersion('not a version'), isFalse);
    });
  });

  group('fast path', () {
    test('asks the host once, for every branch, naming none of them', () async {
      final exec = _forEachRef(
        '${_row('refs/heads/one', _oneOid, 3, 1)}\n'
        '${_row('refs/heads/two', _twoOid, 0, 7)}\n',
      );
      final git = GitService(exec);

      await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: _branches,
        useAheadBehindAtom: true,
      );

      expect(exec.calls, hasLength(1), reason: 'one walk, not one per branch');
      final argv = exec.calls.single.gitArgs;
      expect(argv.first, 'git');
      expect(argv, contains('for-each-ref'));
      expect(argv.join(' '), contains('%(ahead-behind:$_base)'));
      expect(
        argv.join(' '),
        isNot(contains(_oneOid)),
        reason:
            'no branch OID and no ref name enters argv — the refs come back '
            'in OUTPUT, which is stronger than the ordinal join it replaces',
      );
      expect(argv.join(' '), isNot(contains('refs/heads/one')));
      expect(exec.calls.single.lane, ExecLane.read);
    });

    test('ahead and behind land in the right fields', () async {
      // THE assertion. `%(ahead-behind:)` emits ahead first; the fallback's
      // `rev-list --left-right --count` emits behind first. A transposition here
      // is invisible except as every branch reporting its divergence backwards.
      final git = GitService(
        _forEachRef('${_row('refs/heads/one', _oneOid, 5, 2)}\n'),
      );

      final result = await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: const [(refName: 'refs/heads/one', oid: _oneOid)],
        useAheadBehindAtom: true,
      );

      final summary = result.summariesByRefName['refs/heads/one']!;
      expect(summary.aheadOfBase, 5);
      expect(summary.behindBase, 2);
      expect(summary.mergedIntoBase, isFalse);
      expect(summary.shortName, 'one');
      expect(summary.baseOid, _base);
      expect(summary.branchOid, _oneOid);
    });

    test('a branch level with the base reads as merged', () async {
      final git = GitService(
        _forEachRef('${_row('refs/heads/one', _oneOid, 0, 4)}\n'),
      );

      final result = await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: const [(refName: 'refs/heads/one', oid: _oneOid)],
        useAheadBehindAtom: true,
      );

      expect(result.summariesByRefName['refs/heads/one']!.mergedIntoBase, true);
    });

    test('a ref whose tip moved is a failure, never a wrong number', () async {
      // The one semantic difference from the fallback: the batch path computes
      // against the OID it was handed, this path against the ref as it is now.
      // Reporting counts for a tip the caller did not ask about would be worse
      // than reporting that it could not answer.
      final git = GitService(
        _forEachRef('${_row('refs/heads/one', _movedOid, 9, 9)}\n'),
      );

      final result = await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: const [(refName: 'refs/heads/one', oid: _oneOid)],
        useAheadBehindAtom: true,
      );

      expect(result.summariesByRefName, isEmpty);
      expect(
        result.failuresByRefName['refs/heads/one']!.reasonCode,
        'oidMismatch',
      );
    });

    test('a branch absent from the walk is a missingRecord', () async {
      final git = GitService(
        _forEachRef('${_row('refs/heads/one', _oneOid, 1, 1)}\n'),
      );

      final result = await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: _branches,
        useAheadBehindAtom: true,
      );

      expect(result.summariesByRefName.keys, ['refs/heads/one']);
      expect(
        result.failuresByRefName['refs/heads/two']!.reasonCode,
        'missingRecord',
      );
    });

    test('refs outside the request are ignored, not invented', () async {
      final git = GitService(
        _forEachRef(
          '${_row('refs/heads/one', _oneOid, 1, 1)}\n'
          '${_row('refs/heads/unasked', _twoOid, 2, 2)}\n',
        ),
      );

      final result = await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: const [(refName: 'refs/heads/one', oid: _oneOid)],
        useAheadBehindAtom: true,
      );

      expect(result.summariesByRefName.keys, ['refs/heads/one']);
      expect(result.failuresByRefName, isEmpty);
    });
  });

  group('fallback', () {
    test('a non-zero exit re-asks the slow way', () async {
      // An older Git rejects the atom outright ("unknown field name"), and the
      // fast path must not turn that into a broken Branches tab.
      var call = 0;
      final exec = MockExecutor(
        onExecute: (c) {
          call++;
          // First call is the for-each-ref probe; fail it.
          if (c.gitArgs.contains('for-each-ref')) {
            return const SSHCommandResult(
              exitCode: 129,
              stdout: '',
              stderr: 'fatal: unknown field name: ahead-behind',
            );
          }
          return null;
        },
        defaultResult: const SSHCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        ),
      );
      final git = GitService(exec);

      final result = await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: _branches,
        useAheadBehindAtom: true,
      );

      expect(call, greaterThan(1), reason: 'it asked again, the batch way');
      expect(
        exec.calls.any((c) => c.gitArgs.contains('sh')),
        isTrue,
        reason: 'the fallback is the shipped batch script',
      );
      // The batch produced no records, so every branch is a missingRecord —
      // the point is that it RAN, not what an empty stdout yields.
      expect(result.failuresByRefName, hasLength(2));
    });

    test('unparsable output re-asks the slow way', () async {
      final exec = MockExecutor(
        onExecute: (c) => c.gitArgs.contains('for-each-ref')
            ? const SSHCommandResult(
                exitCode: 0,
                stdout: 'this is not the format we asked for\n',
                stderr: '',
              )
            : null,
        defaultResult: const SSHCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        ),
      );
      final git = GitService(exec);

      await git.branchReviewSummaries(
        _repo,
        baseOid: _base,
        branches: _branches,
        useAheadBehindAtom: true,
      );

      expect(exec.calls.any((c) => c.gitArgs.contains('sh')), isTrue);
    });

    test(
      'without the capability the host is never asked for the atom',
      () async {
        final exec = MockExecutor(
          defaultResult: const SSHCommandResult(
            exitCode: 0,
            stdout: '',
            stderr: '',
          ),
        );
        final git = GitService(exec);

        await git.branchReviewSummaries(
          _repo,
          baseOid: _base,
          branches: _branches,
        );

        expect(
          exec.calls.any((c) => c.gitArgs.contains('for-each-ref')),
          isFalse,
          reason:
              'the default is the fallback, which is why no existing caller '
              'or test had to change',
        );
      },
    );
  });
}
