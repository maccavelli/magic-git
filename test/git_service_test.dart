import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

const _repo = '/repo';

/// Builds a [MockExecutor] whose [MockExecutor.onExecute] returns [result] for
/// every call.
MockExecutor _fixed(SSHCommandResult result) => MockExecutor(
  onExecute: (_) => result,
);

/// Builds a [MockExecutor] whose [MockExecutor.onExecute] returns a zero-exit
/// empty result for every call.
MockExecutor _ok() => _fixed(
  const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
);

void main() {
  group('constructor helpers', () {
    test('registerRepoScope / unregisterRepoScope / isRepoScoped', () {
      final executor = MockExecutor();
      final service = GitService(executor);
      expect(service.isRepoScoped(_repo), isFalse);
      service.registerRepoScope(
        _repo,
        gitDir: '/repo/.git',
        workTree: '/repo',
      );
      expect(service.isRepoScoped(_repo), isTrue);

      service.unregisterRepoScope(_repo);
      expect(service.isRepoScoped(_repo), isFalse);
    });

    test('clearAllRepoScopes drops all scopes', () {
      final executor = MockExecutor();
      final service = GitService(executor);
      service.registerRepoScope('/a', gitDir: '/a/.git');
      service.registerRepoScope('/b', gitDir: '/b/.git');
      service.clearAllRepoScopes();
      expect(service.isRepoScoped('/a'), isFalse);
      expect(service.isRepoScoped('/b'), isFalse);
    });
  });

  group('validateRepoPath', () {
    test('succeeds when inside a work tree', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0, stdout: 'true\n', stderr: '',
      ));
      final service = GitService(executor);
      await service.validateRepoPath(_repo);
      expect(executor.lastArgs, [
        'git', 'rev-parse', '--is-inside-work-tree',
      ]);
    });

    test('throws GitException when git is not found (exit 127)', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 127, stdout: '', stderr: 'git: not found',
      )));
      expect(
        () => service.validateRepoPath(_repo),
        throwsA(isA<GitException>()),
      );
    });

    test('throws GitException when outside a work tree', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 128, stdout: 'false\n', stderr: 'fatal: not a git repository',
      )));
      expect(
        () => service.validateRepoPath(_repo),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('listTrackedFiles', () {
    test('splits NUL-delimited output into file list', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0,
        stdout: 'a.dart\u0000b.dart\u0000c.dart\u0000',
        stderr: '',
      ));
      final service = GitService(executor);
      final files = await service.listTrackedFiles(_repo);
      expect(files, ['a.dart', 'b.dart', 'c.dart']);
      expect(executor.lastArgs!.contains('ls-files'), isTrue);
    });

    test('empty output yields empty list', () async {
      final service = GitService(_ok());
      expect(await service.listTrackedFiles(_repo), isEmpty);
    });
  });

  group('resolveShaPrefix', () {
    test('returns resolved hashes from rev-parse output', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0,
        stdout:
            'abc123def456abc123def456abc123def456abc12\n'
            'abc123def456abc123def456abc123def456abc78\n',
        stderr: '',
      ));
      final service = GitService(executor);
      // Minimum prefix length is 4 hex chars (isResolvableShaPrefix).
      final result = await service.resolveShaPrefix(
        _repo, 'abc123',
      );
      expect(result, [
        'abc123def456abc123def456abc123def456abc12',
        'abc123def456abc123def456abc123def456abc78',
      ]);
    });

    test('empty prefix returns empty (fast path)', () async {
      final executor = MockExecutor();
      final service = GitService(executor);
      expect(await service.resolveShaPrefix(_repo, ''), isEmpty);
      expect(executor.calls, isEmpty);
    });

    test('non-zero exit returns empty', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 1, stdout: '', stderr: '',
      )));
      expect(await service.resolveShaPrefix(_repo, 'abc'), isEmpty);
    });
  });

  group('checkIgnore', () {
    test('empty paths returns empty set', () async {
      final executor = MockExecutor();
      final service = GitService(executor);
      expect(await service.checkIgnore(_repo, []), isEmpty);
      expect(executor.calls, isEmpty);
    });

    test('none ignored (exit 1) returns empty set', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 1, stdout: '', stderr: '',
      )));
      expect(await service.checkIgnore(_repo, ['a.txt']), isEmpty);
    });

    test('some ignored returns their paths', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 0,
        stdout: 'ignored.log\u0000build/\u0000',
        stderr: '',
      )));
      final result = await service.checkIgnore(
        _repo, ['a.txt', 'ignored.log', 'build/'],
      );
      expect(result, {'ignored.log', 'build/'});
    });

    test('non-zero non-1 exit fails open (empty set)', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 127, stdout: '', stderr: 'not found',
      )));
      expect(await service.checkIgnore(_repo, ['x']), isEmpty);
    });
  });

  group('diffFile', () {
    test('returns diff stdout', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 0, stdout: '--- a/file\n+++ b/file\n', stderr: '',
      )));
      final diff = await service.diffFile(_repo, path: 'file', staged: false);
      expect(diff, contains('--- a/file'));
    });

    test('uses --cached when staged', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.diffFile(_repo, path: 'f', staged: true);
      expect(executor.lastArgs, contains('--cached'));
    });

    test('uses -w when ignoreWhitespace', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.diffFile(
        _repo, path: 'f', staged: false, ignoreWhitespace: true,
      );
      expect(executor.lastArgs, contains('-w'));
    });

    test('uses -U when context set', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.diffFile(_repo, path: 'f', staged: false, context: 10);
      expect(executor.lastArgs!.any((a) => a == '-U10'), isTrue);
    });

    test('throws GitException on failure', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 1, stdout: '', stderr: 'fatal: bad path',
      )));
      expect(
        () => service.diffFile(_repo, path: 'nosuch', staged: false),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('diffRange', () {
    test('returns diff stdout', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0, stdout: 'diff --git a/x b/x\n', stderr: '',
      ));
      final service = GitService(executor);
      final diff = await service.diffRange(_repo, 'main...feature');
      expect(diff, contains('diff --git'));
      expect(executor.lastArgs, contains('main...feature'));
    });

    test('throws on non-zero', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 1, stdout: '', stderr: 'bad range',
      )));
      expect(
        () => service.diffRange(_repo, 'bad...range'),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('readFile', () {
    test('calls cat and returns stdout', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0, stdout: 'file contents', stderr: '',
      ));
      final service = GitService(executor);
      final content = await service.readFile(_repo, 'readme.md');
      expect(content, 'file contents');
      expect(executor.lastArgs, ['cat', '--', 'readme.md']);
    });

    test('throws on non-zero', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 1, stdout: '', stderr: 'not found',
      )));
      expect(
        () => service.readFile(_repo, 'missing'),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('showBlob', () {
    test('calls git show rev:path', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0, stdout: 'blob content', stderr: '',
      ));
      final service = GitService(executor);
      final content = await service.showBlob(_repo, 'abc123', 'readme.md');
      expect(content, 'blob content');
      expect(executor.lastArgs!.join(' '), contains('abc123:readme.md'));
    });
  });

  group('stage / unstage', () {
    test('stage uses :(literal) path prefix', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.stage(_repo, 'file with spaces.txt');
      expect(
        executor.lastArgs!.join(' '),
        contains(':(literal)file with spaces.txt'),
      );
    });

    test('stageAll calls git add -A', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.stageAll(_repo);
      expect(executor.lastArgs, ['git', 'add', '-A']);
    });

    test('unstage calls git restore --staged', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.unstage(_repo, 'file.dart');
      expect(executor.lastArgs!.join(' '), contains('restore --staged'));
    });

    test('unstageAll calls git reset -q', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.unstageAll(_repo);
      expect(executor.lastArgs, ['git', 'reset', '-q']);
    });

    test('stageMany adds all paths', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.stageMany(_repo, ['a.dart', 'b.dart']);
      final args = executor.lastArgs!.join(' ');
      expect(args, contains(':(literal)a.dart'));
      expect(args, contains(':(literal)b.dart'));
    });
  });

  group('applyPatch', () {
    test('sends patch via stdin', () async {
      String? capturedStdin;
      final executor = MockExecutor(
        onExecute: (call) {
          capturedStdin = call.stdin;
          return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final service = GitService(executor);
      await service.applyPatch(
        _repo, '--- a/x\n+++ b/x\n', cached: false, reverse: false,
      );
      expect(capturedStdin, contains('--- a/x'));
    });

    test('uses --cached and -R flags', () async {
      final executor = _ok();
      final service = GitService(executor);
      await service.applyPatch(_repo, 'patch', cached: true, reverse: true);
      final args = executor.lastArgs!.join(' ');
      expect(args, contains('--cached'));
      expect(args, contains('-R'));
    });
  });

  group('reflog', () {
    test('parses reflog entries from stdout', () async {
      final raw = _reflogRec('a', 'HEAD@{0}', 'commit: initial') +
          _reflogRec('b', 'HEAD@{1}', 'checkout: moving from a to b');
      final executor = _fixed(SSHCommandResult(
        exitCode: 0, stdout: raw, stderr: '',
      ));
      final service = GitService(executor);
      final entries = await service.reflog(_repo);
      expect(entries, hasLength(2));
      expect(entries[0].hash, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(entries[1].subject, 'checkout: moving from a to b');
    });

    test('empty repo (exit 128) returns empty list', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 128, stdout: '', stderr: 'does not have any commits yet',
      )));
      expect(await service.reflog(_repo), isEmpty);
    });

    test('real error still throws', () async {
      final service = GitService(_fixed(const SSHCommandResult(
        exitCode: 128, stdout: '', stderr: 'fatal: unknown option',
      )));
      expect(
        () => service.reflog(_repo),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('_run-based methods', () {
    test('repoLayout parses rev-parse output in correct order', () async {
      // git rev-parse --show-toplevel --git-dir --git-common-dir
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0,
        stdout: '/repo\n/repo/.git\n/repo/.git\n',
        stderr: '',
      ));
      final service = GitService(executor);
      final layout = await service.repoLayout(_repo);
      expect(layout.toplevel, '/repo');
      expect(layout.gitDir, '/repo/.git');
      expect(layout.gitCommonDir, '/repo/.git');
      expect(layout.isLinkedWorktree, isFalse);
    });

    test('gitfileRedirectTarget reads .git file and extracts gitdir:', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0,
        stdout: 'gitdir: /home/x/.home.git\n',
        stderr: '',
      ));
      final service = GitService(executor);
      final target = await service.gitfileRedirectTarget(_repo);
      expect(target, '/home/x/.home.git');
    });
  });

  group('scope injection', () {
    test('scope env is passed to executor commands', () async {
      final executor = _fixed(const SSHCommandResult(
        exitCode: 0, stdout: 'true\n', stderr: '',
      ));
      final service = GitService(executor);
      service.registerRepoScope(
        _repo, gitDir: '/repo/.git', workTree: '/repo',
      );

      await service.validateRepoPath(_repo);
      expect(executor.calls.first.extraEnv, {'GIT_DIR': '/repo/.git', 'GIT_WORK_TREE': '/repo'});
    });
  });
}

String _reflogRec(String hashChar, String selector, String subject) {
  final hash = hashChar * 40; // 40-char hash
  return [
    hash,
    hash.substring(0, 7),
    selector,
    subject,
    subject,
  ].join(GitService.fieldSep) + GitService.recordSep;
}
