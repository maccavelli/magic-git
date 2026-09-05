// MADR 0031 Phase 1 — the namespaces an account may create a project in.
//
// Host-explicit on both forges: at create time the project does not exist, so
// there is no origin to infer a host from. That is the whole reason these do
// not reuse the ambient-host paths.
//
// The failure contract is as load-bearing as the success one. A create sheet
// whose namespace field is free text does not need this list to work, so an
// API that 404s, times out, or answers with HTML must yield an empty list and
// let the user type — never throw into the sheet.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<Map<String, String>?> envs = [];
  final List<SSHCommandResult> results = [];
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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    calls.add(gitArgs);
    envs.add(extraEnv);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// `glab api -i` output: header block, blank line, then the body.
SSHCommandResult _okWithHeaders(String body) =>
    _ok('HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n$body');

void main() {
  group('GlabService.listCreatableNamespaces', () {
    test('own namespace first, then groups by full path', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.results.addAll([
        _okWithHeaders('{"username":"testuser"}'),
        _okWithHeaders(
          '[{"full_path":"team/subgroup"},{"full_path":"platform"}]',
        ),
      ]);

      final namespaces = await glab.listCreatableNamespaces(
        '/repo',
        host: 'gitlab.example',
      );

      expect(namespaces, ['testuser', 'team/subgroup', 'platform']);
    });

    test('asks for groups the account can actually create in', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.results.addAll([
        _okWithHeaders('{"username":"testuser"}'),
        _okWithHeaders('[]'),
      ]);

      await glab.listCreatableNamespaces('/repo', host: 'gitlab.example');

      final groupCall = exec.calls.last.join(' ');
      // min_access_level=30 is Developer, the floor for creating a project.
      expect(groupCall, contains('min_access_level=30'));
      // `namespaces` lists what the account can SEE, including other people's
      // personal namespaces it cannot create in. Verified live; MADR 0031.
      expect(groupCall, isNot(contains('namespaces')));
      // No origin exists yet, so the host must be explicit.
      expect(groupCall, contains('gitlab.example'));
    });

    test('a failing groups call still yields the own namespace', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.results.addAll([
        _okWithHeaders('{"username":"testuser"}'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: '404'),
      ]);

      expect(
        await glab.listCreatableNamespaces('/repo', host: 'gitlab.example'),
        ['testuser'],
      );
    });

    test('non-JSON answers yield an empty list rather than throwing', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.next = _ok('<html>gateway timeout</html>');

      expect(
        await glab.listCreatableNamespaces('/repo', host: 'gitlab.example'),
        isEmpty,
      );
    });
  });

  group('GhService.listCreatableNamespaces', () {
    test('login first, then organisation logins', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.results.addAll([
        _ok('{"login":"testuser"}'),
        _ok('[{"login":"acme-eng"},{"login":"acme-infra"}]'),
      ]);

      final namespaces = await gh.listCreatableNamespaces(
        '/repo',
        host: 'github.com',
      );

      expect(namespaces, ['testuser', 'acme-eng', 'acme-infra']);
    });

    test('a non-default host is selected via GH_HOST', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.results.addAll([_ok('{"login":"testuser"}'), _ok('[]')]);

      await gh.listCreatableNamespaces('/repo', host: 'ghe.example');

      // `every` on an empty list is vacuously true, so pin the call count
      // first — this assertion passed against the empty stub without it.
      expect(exec.envs, hasLength(2));
      expect(exec.envs.every((e) => e?['GH_HOST'] == 'ghe.example'), isTrue);
    });

    test('a failing orgs call still yields the login', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.results.addAll([
        _ok('{"login":"testuser"}'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      ]);

      expect(await gh.listCreatableNamespaces('/repo', host: 'github.com'), [
        'testuser',
      ]);
    });

    test('non-JSON answers yield an empty list rather than throwing', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.next = _ok('not json at all');

      expect(
        await gh.listCreatableNamespaces('/repo', host: 'github.com'),
        isEmpty,
      );
    });
  });
}
