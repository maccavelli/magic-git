import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

const _repo = '/repo';
const _base = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _branch = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _mergeBase = 'cccccccccccccccccccccccccccccccccccccccc';

void main() {
  group('parseNameStatusZ / parseNumstatZ', () {
    test('parses ordinary and rename records with NUL framing', () {
      final names = parseNameStatusZ(
        'M\u0000src/a.dart\u0000'
        'R100\u0000old/path.dart\u0000new/path.dart\u0000'
        'A\u0000added.txt\u0000',
      );
      expect(names, hasLength(3));
      expect(names[0].status, 'M');
      expect(names[0].path, 'src/a.dart');
      expect(names[1].oldPath, 'old/path.dart');
      expect(names[1].path, 'new/path.dart');
      expect(names[2].status, 'A');
    });

    test('parses numstat including binary and rename forms', () {
      final stats = parseNumstatZ(
        '3\t1\tsrc/a.dart\u0000'
        '-\t-\tbin/data.png\u0000'
        '2\t0\u0000old/x\u0000new/x\u0000',
      );
      expect(stats['src/a.dart']?.additions, 3);
      expect(stats['src/a.dart']?.deletions, 1);
      expect(stats['bin/data.png']?.binary, isTrue);
      expect(stats['new/x']?.additions, 2);
    });

    test('assemble joins stats and applies truncation', () {
      final nameStatus = StringBuffer();
      final numstat = StringBuffer();
      for (var i = 0; i < 5; i++) {
        nameStatus.write('A\u0000f$i.txt\u0000');
        numstat.write('1\t0\tf$i.txt\u0000');
      }
      final meta = assembleComparisonMetadata(
        baseOid: _base,
        branchOid: _branch,
        mergeBaseOid: _mergeBase,
        nameStatusZ: nameStatus.toString(),
        numstatZ: numstat.toString(),
        maxFiles: 3,
      );
      expect(meta.truncated, isTrue);
      expect(meta.files, hasLength(3));
      expect(meta.additions, 3);
      expect(meta.ancestry, ComparisonAncestry.connected);
      expect(meta.method, BranchComparisonMethod.threeDot);
    });
  });

  group('GitService.branchComparisonMetadata', () {
    test('unrelated histories skip three-dot diff', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(exitCode: 1, stdout: '', stderr: '');
          }
          fail('diff must not run for unrelated: $args');
        },
      );
      final meta = await GitService(
        exec,
      ).branchComparisonMetadata(_repo, baseOid: _base, branchOid: _branch);
      expect(meta.ancestry, ComparisonAncestry.unrelated);
      expect(meta.mergeBaseOid, isNull);
      expect(meta.files, isEmpty);
      expect(exec.calls, hasLength(1));
    });

    test('connected history uses three-dot range and parses files', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: '$_mergeBase\n',
              stderr: '',
            );
          }
          if (args.contains('sh') && args.contains('branch-cmp')) {
            const sep = '\u0002RMGCMP\u0002';
            const stdout =
                '${sep}NS\n'
                'M\u0000lib/a.dart\u0000'
                '$sep'
                'NU\n'
                '4\t2\tlib/a.dart\u0000'
                '$sep'
                'EC\n0 0\n';
            return const SSHCommandResult(
              exitCode: 0,
              stdout: stdout,
              stderr: '',
            );
          }
          fail('unexpected: $args');
        },
      );
      final meta = await GitService(
        exec,
      ).branchComparisonMetadata(_repo, baseOid: _base, branchOid: _branch);
      expect(meta.ancestry, ComparisonAncestry.connected);
      expect(meta.mergeBaseOid, _mergeBase);
      expect(meta.files.single.path, 'lib/a.dart');
      expect(meta.additions, 4);
      expect(meta.deletions, 2);
      final scriptArgs = exec.calls[1].gitArgs;
      expect(scriptArgs, contains(_base));
      expect(scriptArgs, contains(_branch));
      expect(scriptArgs.join(' '), contains(r'$base...$branch'));
    });

    test('rejects short OIDs before executing', () async {
      final exec = MockExecutor();
      await expectLater(
        GitService(
          exec,
        ).branchComparisonMetadata(_repo, baseOid: 'short', branchOid: _branch),
        throwsArgumentError,
      );
      expect(exec.calls, isEmpty);
    });

    test('marker collision falls back to separate invocations', () async {
      var calls = 0;
      final exec = MockExecutor(
        onExecute: (call) {
          calls++;
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: '$_mergeBase\n',
              stderr: '',
            );
          }
          if (args.contains('sh') && args.contains('branch-cmp')) {
            // Malformed framing — missing sections.
            return const SSHCommandResult(
              exitCode: 0,
              stdout: 'garbage without markers',
              stderr: '',
            );
          }
          if (args.contains('--name-status')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: 'A\u0000only.txt\u0000',
              stderr: '',
            );
          }
          if (args.contains('--numstat')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: '1\t0\tonly.txt\u0000',
              stderr: '',
            );
          }
          fail('unexpected: $args');
        },
      );
      final meta = await GitService(
        exec,
      ).branchComparisonMetadata(_repo, baseOid: _base, branchOid: _branch);
      expect(meta.files.single.path, 'only.txt');
      expect(calls, greaterThanOrEqualTo(4)); // mb + combined + ns + nu
    });

    test('empty connected diff returns zero files, not unrelated', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: '$_mergeBase\n',
              stderr: '',
            );
          }
          if (args.contains('sh') && args.contains('branch-cmp')) {
            const sep = '\u0002RMGCMP\u0002';
            const stdout =
                '${sep}NS\n'
                '$sep'
                'NU\n'
                '$sep'
                'EC\n0 0\n';
            return const SSHCommandResult(
              exitCode: 0,
              stdout: stdout,
              stderr: '',
            );
          }
          fail('unexpected: $args');
        },
      );
      final meta = await GitService(
        exec,
      ).branchComparisonMetadata(_repo, baseOid: _base, branchOid: _branch);
      expect(meta.ancestry, ComparisonAncestry.connected);
      expect(meta.files, isEmpty);
      expect(meta.additions, 0);
      expect(meta.deletions, 0);
      expect(meta.truncated, isFalse);
    });

    test('merge-base hard failure is an error, not unrelated', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(
              exitCode: 128,
              stdout: '',
              stderr: 'fatal: Not a valid object name',
            );
          }
          fail('diff must not run on merge-base failure: $args');
        },
      );
      await expectLater(
        GitService(
          exec,
        ).branchComparisonMetadata(_repo, baseOid: _base, branchOid: _branch),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('path edge cases', () {
    test(
      'parses Unicode, tab, and newline path segments under NUL framing',
      () {
        const unicode = 'docs/日本語.md';
        const withTab = 'a\tb.txt';
        const withNl = 'line\nbreak.c';
        final names = parseNameStatusZ(
          'M\u0000$unicode\u0000'
          'A\u0000$withTab\u0000'
          'D\u0000$withNl\u0000'
          'R100\u0000old name\u0000new name\u0000',
        );
        expect(names.map((n) => n.path).toList(), [
          unicode,
          withTab,
          withNl,
          'new name',
        ]);
        expect(names[3].oldPath, 'old name');

        final stats = parseNumstatZ(
          '1\t0\t$unicode\u0000'
          '2\t1\t$withTab\u0000'
          '-\t-\t$withNl\u0000'
          '3\t0\u0000old name\u0000new name\u0000',
        );
        expect(stats[unicode]?.additions, 1);
        expect(stats[withTab]?.deletions, 1);
        expect(stats[withNl]?.binary, isTrue);
        expect(stats['new name']?.additions, 3);

        final meta = assembleComparisonMetadata(
          baseOid: _base,
          branchOid: _branch,
          mergeBaseOid: _mergeBase,
          nameStatusZ:
              'M\u0000$unicode\u0000'
              'A\u0000$withTab\u0000',
          numstatZ:
              '1\t0\t$unicode\u0000'
              '2\t1\t$withTab\u0000',
        );
        expect(meta.files, hasLength(2));
        expect(meta.additions, 3);
        expect(meta.deletions, 1);
      },
    );

    test('copy status is parsed like rename', () {
      final names = parseNameStatusZ('C080\u0000src\u0000dst\u0000');
      expect(names.single.status, 'C080');
      expect(names.single.oldPath, 'src');
      expect(names.single.path, 'dst');
    });
  });
}
