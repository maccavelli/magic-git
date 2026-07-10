// parseCliAuthHost + GhService/GlabService.authenticatedHost: the wizards
// prefill their forge-host fields with the instance the target's gh/glab is
// actually signed in to, instead of the stock github.com/gitlab.com default.
// Signed-out / missing-CLI cases must yield null (keep the stock default),
// never a garbage host.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
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
  }) async {
    calls.add(gitArgs);
    return next;
  }
}

void main() {
  group('parseCliAuthHost', () {
    test('single gh host', () {
      const out = '''
github.com
  ✓ Logged in to github.com account maccavelli (keyring)
  - Active account: true
  - Git operations protocol: https
''';
      expect(parseCliAuthHost(out), 'github.com');
    });

    test('multiple gh hosts — the active account wins over the first', () {
      const out = '''
github.com
  ✓ Logged in to github.com account personal (keyring)
  - Active account: false

ghe.corp.example
  ✓ Logged in to ghe.corp.example account work (keyring)
  - Active account: true
''';
      expect(parseCliAuthHost(out), 'ghe.corp.example');
    });

    test('no active marker (glab style) — first host wins', () {
      const out = '''
gitlab.lkqdev.com
  ✓ Logged in to gitlab.lkqdev.com as saxsmith (glab-config)
  ✓ Git operations for gitlab.lkqdev.com configured to use https protocol.
''';
      expect(parseCliAuthHost(out), 'gitlab.lkqdev.com');
    });

    test('trailing colon and :port forms are handled', () {
      expect(parseCliAuthHost('gitlab.example.com:\n  ✓ Logged in'),
          'gitlab.example.com');
      expect(parseCliAuthHost('gitlab.example.com:8443\n  ✓ Logged in'),
          'gitlab.example.com:8443');
    });

    test('single-label internal hostnames are accepted', () {
      expect(parseCliAuthHost('gitbox\n  ✓ Logged in to gitbox'), 'gitbox');
    });

    test('signed-out prose yields null', () {
      expect(
        parseCliAuthHost('You are not logged into any GitHub hosts. '
            'To log in, run: gh auth login'),
        isNull,
      );
      expect(parseCliAuthHost(''), isNull);
    });
  });

  group('authenticatedHost', () {
    test('gh: parses stdout and issues gh auth status', () async {
      final exec = _FakeExecutor()
        ..next = const SSHCommandResult(
          exitCode: 0,
          stdout: 'github.com\n  - Active account: true\n',
          stderr: '',
        );
      expect(await GhService(exec).authenticatedHost(), 'github.com');
      expect(exec.calls.single, ['gh', 'auth', 'status']);
    });

    test('glab: host arriving on stderr is still found', () async {
      final exec = _FakeExecutor()
        ..next = const SSHCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: 'gitlab.lkqdev.com\n  ✓ Logged in as saxsmith\n',
        );
      expect(
        await GlabService(exec).authenticatedHost(),
        'gitlab.lkqdev.com',
      );
      expect(exec.calls.single, ['glab', 'auth', 'status']);
    });

    test('signed out (non-zero exit, prose only) yields null', () async {
      final exec = _FakeExecutor()
        ..next = const SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'You are not logged into any GitHub hosts.',
        );
      expect(await GhService(exec).authenticatedHost(), isNull);
    });
  });
}
