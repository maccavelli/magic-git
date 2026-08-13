import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_urls.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

void main() {
  group('forgeBranchNameForCreateSeed', () {
    test('normalizes local, origin, and omits tags/other remotes', () {
      expect(forgeBranchNameForCreateSeed('refs/heads/main'), 'main');
      expect(forgeBranchNameForCreateSeed('main'), 'main');
      expect(forgeBranchNameForCreateSeed('refs/remotes/origin/main'), 'main');
      expect(forgeBranchNameForCreateSeed('origin/main'), 'main');
      expect(forgeBranchNameForCreateSeed('refs/tags/v1'), isNull);
      expect(forgeBranchNameForCreateSeed('refs/remotes/upstream/main'), isNull);
      expect(
        forgeBranchNameForCreateSeed(
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        isNull,
      );
    });
  });

  group('forgeBranchWebUrl', () {
    test('builds github and gitlab tree URLs', () {
      expect(
        forgeBranchWebUrl(
          'git@github.com:acme/app.git',
          Forge.github,
          'feature/x',
        ),
        'https://github.com/acme/app/tree/feature%2Fx',
      );
      expect(
        forgeBranchWebUrl(
          'https://gitlab.com/acme/app.git',
          Forge.gitlab,
          'main',
        ),
        'https://gitlab.com/acme/app/-/tree/main',
      );
      expect(
        forgeBranchWebUrl('git@github.com:acme/app.git', Forge.none, 'main'),
        isNull,
      );
    });
  });

  group('GitService.push publish argv', () {
    test('uses -u, remote, branch, and no force', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs;
          expect(args, contains('push'));
          expect(args, contains('-u'));
          expect(args, contains('origin'));
          expect(args, contains('feature'));
          expect(args, isNot(contains('--force')));
          expect(args, isNot(contains('--force-with-lease')));
          return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitService(exec).push(
        '/repo',
        remote: 'origin',
        branch: 'feature',
        setUpstream: true,
        force: PushForce.none,
      );
    });
  });

  group('defaultRemote', () {
    test('prefers origin then first', () {
      expect(defaultRemote(['upstream', 'origin']), 'origin');
      expect(defaultRemote(['upstream']), 'upstream');
    });
  });
}
