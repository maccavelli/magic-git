import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/command_formatter.dart';

void main() {
  group('CommandFormatter.format', () {
    test('includes default env prelude and cd', () {
      final cmd = CommandFormatter.format(
        repoPath: '/srv/repo',
        gitArgs: ['git', 'status'],
      );
      expect(cmd, contains("GIT_TERMINAL_PROMPT='0'"));
      expect(cmd, contains("GIT_EDITOR='true'"));
      expect(cmd, contains("GIT_OPTIONAL_LOCKS='0'"));
      // Error classification matches English stderr substrings; a host with a
      // non-English LANG must not defeat it (LC_MESSAGES, not LC_ALL, so path
      // encoding is untouched).
      expect(cmd, contains("LC_MESSAGES='C'"));
      expect(cmd, contains("cd '/srv/repo'"));
      expect(cmd, endsWith("&& exec 'git' 'status'"));
    });

    test('escapes repo path and every argv element', () {
      final cmd = CommandFormatter.format(
        repoPath: "/tmp/my repo'; evil",
        gitArgs: ['git', 'commit', '-m', "fix; drop table"],
      );
      expect(cmd, contains("cd '/tmp/my repo'\\''; evil'"));
      expect(cmd, contains("'fix; drop table'"));
    });

    test('empty extra env uses defaults only', () {
      final cmd = CommandFormatter.format(
        repoPath: '/r',
        gitArgs: ['git', 'fetch'],
        env: {},
      );
      expect(cmd, contains("cd '/r' &&"));
      expect(cmd, isNot(contains('export')));
    });

    test(
      'unsets only the neutralizeEnv vars, first, and nothing when empty',
      () {
        // No neutralization requested → no `unset` prelude, leaving the remote's
        // own gh/glab auth untouched (the no-token-supplied case).
        final bare = CommandFormatter.format(
          repoPath: '/r',
          gitArgs: ['git', 'fetch'],
          env: {},
        );
        expect(bare, isNot(contains('unset ')));

        // A forge token was supplied → its vars are unset before anything else.
        final neutralized = CommandFormatter.format(
          repoPath: '/r',
          gitArgs: ['git', 'fetch'],
          env: {},
          neutralizeEnv: CommandFormatter.githubTokenVars,
        );
        expect(
          neutralized,
          startsWith(
            'unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN '
            'GITHUB_ENTERPRISE_TOKEN; ',
          ),
        );
      },
    );

    test('rejects a neutralizeEnv name with shell metacharacters', () {
      // Unset names are interpolated raw into the shell string, so they get
      // the same defense-in-depth validation as env keys — a name carrying
      // metacharacters must throw, never reach the command string.
      expect(
        () => CommandFormatter.format(
          repoPath: '/r',
          gitArgs: ['git', 'fetch'],
          env: {},
          neutralizeEnv: const ['GH_TOKEN; rm -rf /'],
        ),
        throwsArgumentError,
      );
    });

    test('merges custom env over defaults when passed via executor path', () {
      // CommandFormatter itself replaces env wholesale; executor merges.
      final cmd = CommandFormatter.format(
        repoPath: '/r',
        gitArgs: ['true'],
        env: {'FOO': 'bar'},
      );
      expect(cmd, contains("FOO='bar'"));
      expect(cmd, isNot(contains('GIT_OPTIONAL_LOCKS')));
    });

    test('rewrites argv[0] to a resolved binary path', () {
      final cmd = CommandFormatter.format(
        repoPath: '/r',
        gitArgs: ['glab', 'auth', 'status'],
        binaryPaths: const {'glab': '/opt/homebrew/bin/glab'},
      );
      expect(cmd, endsWith("&& exec '/opt/homebrew/bin/glab' 'auth' 'status'"));
      expect(cmd, isNot(contains("'glab' 'auth'")));
    });

    test('leaves argv unchanged when no binary override matches', () {
      final cmd = CommandFormatter.format(
        repoPath: '/r',
        gitArgs: ['sh', '-c', 'inotifywait .'],
        binaryPaths: const {'glab': '/opt/homebrew/bin/glab'},
      );
      expect(cmd, endsWith("&& exec 'sh' '-c' 'inotifywait .'"));
    });

    test('accepts a well-formed env key', () {
      final cmd = CommandFormatter.format(
        repoPath: '/r',
        gitArgs: ['git', 'status'],
        env: {'PATH_2': '/usr/bin'},
      );
      expect(cmd, contains("PATH_2='/usr/bin'"));
    });

    test('rejects an env key with shell metacharacters', () {
      // Values are escaped, but keys interpolate raw — a key carrying shell
      // syntax must be refused rather than injected into the export prelude.
      expect(
        () => CommandFormatter.format(
          repoPath: '/r',
          gitArgs: ['git', 'status'],
          env: {'FOO; rm -rf /': 'x'},
        ),
        throwsArgumentError,
      );
    });

    test('rejects an env key that does not start with a letter/underscore', () {
      expect(
        () => CommandFormatter.format(
          repoPath: '/r',
          gitArgs: ['git', 'status'],
          env: {'1BAD': 'x'},
        ),
        throwsArgumentError,
      );
    });
  });

  group('compressOutput', () {
    test('wraps the command in an exit-trailer group piped through gzip', () {
      final cmd = CommandFormatter.format(
        repoPath: '/repo',
        gitArgs: ['git', 'log'],
        compressOutput: true,
      );
      expect(
        cmd,
        contains(
          "{ 'git' 'log'; printf '\\001EXIT=%d\\001' \"\$?\"; } | 'gzip' -c -1",
        ),
      );
      // No `exec` — the shell must survive the command to emit the trailer.
      expect(cmd, isNot(contains('exec ')));
    });

    test('uses the resolved absolute gzip path when provided', () {
      final cmd = CommandFormatter.format(
        repoPath: '/repo',
        gitArgs: ['git', 'log'],
        binaryPaths: const {'gzip': '/opt/homebrew/bin/gzip'},
        compressOutput: true,
      );
      expect(cmd, contains("| '/opt/homebrew/bin/gzip' -c -1"));
      expect(cmd, isNot(contains("| 'gzip' -c -1")));
    });

    test('still escapes every argument inside the group', () {
      final cmd = CommandFormatter.format(
        repoPath: '/repo',
        gitArgs: ['git', 'show', r"evil'; rm -rf /"],
        compressOutput: true,
      );
      expect(cmd, contains(r"'evil'\''; rm -rf /'"));
    });

    test('false keeps the exec form untouched', () {
      final cmd = CommandFormatter.format(
        repoPath: '/repo',
        gitArgs: ['git', 'log'],
      );
      expect(cmd, endsWith("exec 'git' 'log'"));
      expect(cmd, isNot(contains('gzip')));
    });
  });
}
