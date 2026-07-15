// Repo-level forge operations behind clone-from-forge / create-repo:
// host-explicit login (token via stdin, NEVER argv/env), account repo listing
// with GH_HOST/GITLAB_HOST scoping, create argv shapes, and the pure clone
// argv builders. Mirrors the gh_http_test/mutations_test harness.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_repo_summary.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<String?> stdins = [];
  final List<Map<String, String>?> envs = [];
  final List<String> repoPaths = [];
  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );
  final List<SSHCommandResult> results = [];

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
    stdins.add(stdin);
    envs.add(extraEnv);
    repoPaths.add(repoPath);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

const _ghRepoJson = '''
[
  {"nameWithOwner":"mac/magic-git","description":"a git client",
   "isPrivate":true,"url":"https://github.com/mac/magic-git",
   "sshUrl":"git@github.com:mac/magic-git.git",
   "updatedAt":"2026-07-01T00:00:00Z"},
  {"nameWithOwner":"mac/dotfiles","description":null,
   "isPrivate":false,"url":"https://github.com/mac/dotfiles",
   "sshUrl":"git@github.com:mac/dotfiles.git","updatedAt":null}
]
''';

const _glabHeaders = 'HTTP/2.0 200 OK\nContent-Type: application/json\n\n';
const _glabProjectsJson = '''
[
  {"path_with_namespace":"group/proj","description":"desc",
   "visibility":"private","web_url":"https://gitlab.com/group/proj",
   "ssh_url_to_repo":"git@gitlab.com:group/proj.git",
   "last_activity_at":"2026-07-01T00:00:00Z"},
  {"path_with_namespace":"group/pub","description":null,
   "visibility":"public","web_url":"https://gitlab.com/group/pub",
   "ssh_url_to_repo":"git@gitlab.com:group/pub.git",
   "last_activity_at":null}
]
''';

void main() {
  late _FakeExecutor exec;
  late GhService gh;
  late GlabService glab;

  setUp(() {
    exec = _FakeExecutor();
    gh = GhService(exec);
    glab = GlabService(exec);
  });

  group('loginWithTokenHost', () {
    test('gh: token via stdin only, never argv or env', () async {
      await gh.loginWithTokenHost(host: 'ghe.corp.example', token: ' tok123 ');
      final argv = exec.calls.single;
      expect(argv, [
        'gh',
        'auth',
        'login',
        '--hostname',
        'ghe.corp.example',
        '--with-token',
      ]);
      expect(argv.join(' '), isNot(contains('tok123')));
      expect(exec.stdins.single, 'tok123', reason: 'trimmed, via stdin');
      expect(exec.envs.single, isNull);
      expect(exec.repoPaths.single, '.', reason: 'no repo required');
    });

    test('glab: token via stdin only, never argv or env', () async {
      await glab.loginWithTokenHost(host: 'gitlab.corp', token: 'glpat-x');
      final argv = exec.calls.single;
      expect(argv, [
        'glab',
        'auth',
        'login',
        '--hostname',
        'gitlab.corp',
        '--stdin',
      ]);
      expect(argv.join(' '), isNot(contains('glpat-x')));
      expect(exec.stdins.single, 'glpat-x');
      expect(exec.envs.single, isNull);
    });

    test('both refuse a blank token without touching the network', () async {
      await expectLater(
        gh.loginWithTokenHost(host: 'github.com', token: '   '),
        throwsA(isA<GhException>()),
      );
      await expectLater(
        glab.loginWithTokenHost(host: 'gitlab.com', token: ''),
        throwsA(isA<GlabException>()),
      );
      expect(exec.calls, isEmpty);
    });

    test('repo-scoped loginWithToken still resolves host then delegates',
        () async {
      exec.results.add(_ok('git@github.com:mac/x.git\n'));
      exec.results.add(_ok(''));
      await gh.loginWithToken('/srv/repo', 'tok');
      expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[1], containsAllInOrder([
        '--hostname',
        'github.com',
        '--with-token',
      ]));
      expect(exec.stdins[1], 'tok');
    });
  });

  group('gh listRepos', () {
    test('argv shape, no GH_HOST for github.com, JSON mapping', () async {
      exec.next = _ok(_ghRepoJson);
      final repos = await gh.listRepos();
      expect(exec.calls.single.take(3), ['gh', 'repo', 'list']);
      expect(exec.calls.single, containsAllInOrder(['--limit', '100']));
      final jsonIdx = exec.calls.single.indexOf('--json');
      expect(
        exec.calls.single[jsonIdx + 1],
        'nameWithOwner,description,isPrivate,url,sshUrl,updatedAt',
      );
      expect(exec.envs.single, isNull);
      expect(exec.repoPaths.single, '.');

      expect(repos, hasLength(2));
      expect(repos[0].slug, 'mac/magic-git');
      expect(repos[0].isPrivate, isTrue);
      expect(repos[0].name, 'magic-git');
      expect(repos[0].forge, Forge.github);
      expect(repos[1].description, '', reason: 'null description normalized');
    });

    test('a GHE host rides GH_HOST', () async {
      exec.next = _ok('[]');
      await gh.listRepos(host: 'ghe.corp.example');
      expect(exec.envs.single, {'GH_HOST': 'ghe.corp.example'});
    });
  });

  group('glab listRepos', () {
    test('routes through glab api with -i and maps the projects JSON',
        () async {
      exec.next = _ok('$_glabHeaders$_glabProjectsJson');
      final repos = await glab.listRepos();
      final argv = exec.calls.single;
      expect(argv.take(2), ['glab', 'api']);
      expect(argv[2], contains('projects?membership=true'));
      expect(argv[2], contains('per_page=100'));
      expect(argv, containsAllInOrder(['--method', 'GET']));
      expect(argv, contains('-i'));
      expect(exec.envs.single, isNull);

      expect(repos, hasLength(2));
      expect(repos[0].slug, 'group/proj');
      expect(repos[0].isPrivate, isTrue);
      expect(repos[1].isPrivate, isFalse);
      expect(repos[0].forge, Forge.gitlab);
    });

    test('a self-hosted instance rides GITLAB_HOST (and legacy GITLAB_URI)',
        () async {
      exec.next = _ok('$_glabHeaders[]');
      await glab.listRepos(host: 'gitlab.corp');
      expect(exec.envs.single, {
        'GITLAB_HOST': 'gitlab.corp',
        'GITLAB_URI': 'gitlab.corp',
      });
    });

    test('an HTTP 401 behind a zero exit code still throws', () async {
      exec.next = _ok('HTTP/2.0 401 Unauthorized\n\n{"message":"401"}');
      await expectLater(glab.listRepos(), throwsA(isA<GlabException>()));
    });
  });

  group('create', () {
    test('gh createRepoInExisting is API-only (no --source/--remote/--push)',
        () async {
      await gh.createRepoInExisting(
        repoPath: '/srv/code/newrepo',
        name: 'newrepo',
        private: true,
        description: 'my thing',
        host: 'ghe.corp.example',
      );
      expect(exec.calls.single, [
        'gh',
        'repo',
        'create',
        'newrepo',
        '--private',
        '--description',
        'my thing',
      ]);
      expect(exec.repoPaths.single, '/srv/code/newrepo');
      expect(exec.envs.single, {'GH_HOST': 'ghe.corp.example'});
    });

    test('gh createRepoInExisting public minimal', () async {
      await gh.createRepoInExisting(
        repoPath: '/x/r',
        name: 'r',
        private: false,
      );
      expect(exec.calls.single, [
        'gh',
        'repo',
        'create',
        'r',
        '--public',
      ]);
    });

    test('glab createRepoInExisting skips local git setup', () async {
      await glab.createRepoInExisting(
        repoPath: '/srv/code/newrepo',
        name: 'newrepo',
        private: true,
        description: 'd',
      );
      expect(exec.calls.single, [
        'glab',
        'repo',
        'create',
        'newrepo',
        '--private',
        '--description',
        'd',
        '--skipGitInit',
      ]);
      expect(exec.repoPaths.single, '/srv/code/newrepo');
      expect(exec.envs.single, isNull);
    });

    test('create failures throw with the carried result', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'name already exists',
      );
      await expectLater(
        gh.createRepoInExisting(repoPath: '/x/r', name: 'r', private: true),
        throwsA(isA<GhException>()),
      );
      await expectLater(
        glab.createRepoInExisting(repoPath: '/x/r', name: 'r', private: true),
        throwsA(isA<GlabException>()),
      );
    });
  });

  group('cloneUrl (origin repair)', () {
    test('gh: https protocol returns the web URL with a .git suffix', () async {
      exec.results.add(_ok(
        '{"url":"https://github.com/mac/r","sshUrl":"git@github.com:mac/r.git"}',
      )); // gh repo view
      exec.results.add(_ok('https')); // gh config get git_protocol
      final url = await gh.cloneUrl(repoPath: '/x/r', name: 'r');
      expect(url, 'https://github.com/mac/r.git');
      expect(exec.calls[0], ['gh', 'repo', 'view', 'r', '--json', 'url,sshUrl']);
      expect(exec.calls[1], [
        'gh',
        'config',
        'get',
        'git_protocol',
        '-h',
        'github.com',
      ]);
    });

    test('gh: ssh protocol returns the SSH URL verbatim', () async {
      exec.results.add(_ok(
        '{"url":"https://github.com/mac/r","sshUrl":"git@github.com:mac/r.git"}',
      ));
      exec.results.add(_ok('ssh'));
      expect(
        await gh.cloneUrl(repoPath: '/x/r', name: 'r'),
        'git@github.com:mac/r.git',
      );
    });

    test('gh: a GHE host rides GH_HOST on both probes', () async {
      exec.results.add(_ok(
        '{"url":"https://ghe.corp/mac/r","sshUrl":"git@ghe.corp:mac/r.git"}',
      ));
      exec.results.add(_ok('https'));
      await gh.cloneUrl(repoPath: '/x/r', name: 'r', host: 'ghe.corp.example');
      expect(exec.envs[0], {'GH_HOST': 'ghe.corp.example'});
      expect(exec.envs[1], {'GH_HOST': 'ghe.corp.example'});
    });

    test('gh: a failed view yields null (never throws)', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'not found',
      );
      expect(await gh.cloneUrl(repoPath: '/x/r', name: 'r'), isNull);
    });

    test('glab: a bare name resolves the user namespace, then the project URL',
        () async {
      exec.results.add(_ok('$_glabHeaders{"username":"mac"}')); // glab api user
      exec.results.add(_ok(
        '$_glabHeaders{"http_url_to_repo":"https://gitlab.com/mac/r.git"}',
      )); // glab api projects
      final url = await glab.cloneUrl(repoPath: '/x/r', name: 'r');
      expect(url, 'https://gitlab.com/mac/r.git');
      expect(exec.calls[0], ['glab', 'api', 'user', '-i']);
      expect(exec.calls[1], ['glab', 'api', 'projects/mac%2Fr', '-i']);
    });

    test('glab: a group path skips the user lookup and is %2F-encoded',
        () async {
      exec.results.add(_ok(
        '$_glabHeaders{"http_url_to_repo":"https://gitlab.com/grp/sub/r.git"}',
      ));
      final url = await glab.cloneUrl(repoPath: '/x/r', name: 'grp/sub/r');
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/grp%2Fsub%2Fr',
        '-i',
      ]);
      expect(url, 'https://gitlab.com/grp/sub/r.git');
    });

    test('glab: a failed user lookup yields null (never throws)', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'boom',
      );
      expect(await glab.cloneUrl(repoPath: '/x/r', name: 'r'), isNull);
    });
  });

  group('cloneArgv builders', () {
    test('gh', () {
      expect(GhService.cloneArgv(slug: 'mac/magic-git', dirName: 'magic-git'), [
        'gh',
        'repo',
        'clone',
        'mac/magic-git',
        'magic-git',
        '--',
        '--progress',
      ]);
    });

    test('glab', () {
      expect(
        GlabService.cloneArgv(
          pathWithNamespace: 'group/proj',
          dirName: 'proj',
        ),
        ['glab', 'repo', 'clone', 'group/proj', 'proj', '--', '--progress'],
      );
    });
  });

  group('ForgeRepoSummary', () {
    test('name strips the namespace', () {
      const r = ForgeRepoSummary(
        slug: 'a/b/c',
        description: '',
        isPrivate: false,
        webUrl: '',
        sshUrl: '',
        updatedAt: null,
        forge: Forge.gitlab,
      );
      expect(r.name, 'c');
    });

    test('gitlab internal visibility counts as private', () {
      final r = ForgeRepoSummary.fromGlabJson(const {
        'path_with_namespace': 'g/p',
        'visibility': 'internal',
      });
      expect(r.isPrivate, isTrue);
    });
  });
}
