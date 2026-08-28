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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
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
    glab = GlabService(exec)..debugOriginHostOverride = 'gitlab.com';
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
      exec.results.add(_ok('')); // auth login
      exec.results.add(_ok('{"username":"saxsmith"}')); // glab api user
      exec.results.add(_ok('')); // glab config set user
      await glab.loginWithTokenHost(host: 'gitlab.corp', token: 'glpat-x');
      final argv = exec.calls.first;
      expect(argv, [
        'glab',
        'auth',
        'login',
        '--hostname',
        'gitlab.corp',
        '--stdin',
      ]);
      expect(argv.join(' '), isNot(contains('glpat-x')));
      expect(exec.stdins.first, 'glpat-x');
      expect(exec.envs.first, isNull);
    });

    test('glab: records the credential username after login (empty `user` '
        'otherwise breaks HTTPS git)', () async {
      exec.results.add(_ok('')); // auth login
      exec.results.add(
        _ok('{"username":"saxsmith","id":255}'),
      ); // glab api user
      exec.results.add(_ok('')); // glab config set user
      await glab.loginWithTokenHost(host: 'gitlab.corp', token: 'glpat-x');
      // The token that authenticates the API also names the identity to record.
      expect(exec.calls[1], [
        'glab',
        'api',
        '--hostname',
        'gitlab.corp',
        'user',
      ]);
      expect(exec.envs[1], {
        'GITLAB_HOST': 'gitlab.corp',
        'GITLAB_URI': 'gitlab.corp',
      });
      // `--host` long form: glab's `-h` is help, not host.
      expect(exec.calls[2], [
        'glab',
        'config',
        'set',
        'user',
        'saxsmith',
        '--host',
        'gitlab.corp',
      ]);
    });

    test(
      'glab: a failed username probe is non-fatal (login still succeeds)',
      () async {
        exec.results.add(_ok('')); // auth login
        exec.results.add(
          const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'network'),
        ); // glab api user fails
        // Must not throw, and must not attempt `glab config set` with no username.
        await glab.loginWithTokenHost(host: 'gitlab.corp', token: 'glpat-x');
        expect(exec.calls, hasLength(2));
        expect(exec.calls[1], [
          'glab',
          'api',
          '--hostname',
          'gitlab.corp',
          'user',
        ]);
      },
    );

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

    test(
      'repo-scoped loginWithToken still resolves host then delegates',
      () async {
        exec.results.add(_ok('git@github.com:mac/x.git\n'));
        exec.results.add(_ok(''));
        await gh.loginWithToken('/srv/repo', 'tok');
        expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
        expect(
          exec.calls[1],
          containsAllInOrder(['--hostname', 'github.com', '--with-token']),
        );
        expect(exec.stdins[1], 'tok');
      },
    );
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
    test(
      'routes through glab api with -i and maps the projects JSON',
      () async {
        exec.next = _ok('$_glabHeaders$_glabProjectsJson');
        final repos = await glab.listRepos();
        final argv = exec.calls.single;
        expect(argv.take(2), ['glab', 'api']);
        expect(
          argv.firstWhere((a) => a.startsWith('projects?')),
          contains('projects?membership=true'),
        );
        expect(
          argv.firstWhere((a) => a.startsWith('projects?')),
          contains('per_page=100'),
        );
        expect(argv, containsAllInOrder(['--method', 'GET']));
        expect(argv, contains('-i'));
        expect(exec.envs.single, isNull);

        expect(repos, hasLength(2));
        expect(repos[0].slug, 'group/proj');
        expect(repos[0].isPrivate, isTrue);
        expect(repos[1].isPrivate, isFalse);
        expect(repos[0].forge, Forge.gitlab);
      },
    );

    test(
      'a self-hosted instance rides GITLAB_HOST (and legacy GITLAB_URI)',
      () async {
        exec.next = _ok('$_glabHeaders[]');
        await glab.listRepos(host: 'gitlab.corp');
        expect(exec.envs.single, {
          'GITLAB_HOST': 'gitlab.corp',
          'GITLAB_URI': 'gitlab.corp',
        });
      },
    );

    test('an HTTP 401 behind a zero exit code still throws', () async {
      exec.next = _ok('HTTP/2.0 401 Unauthorized\n\n{"message":"401"}');
      await expectLater(glab.listRepos(), throwsA(isA<GlabException>()));
    });
  });

  group('create', () {
    test(
      'gh createRepoInExisting is API-only (no --source/--remote/--push)',
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
      },
    );

    test('gh createRepoInExisting public minimal', () async {
      await gh.createRepoInExisting(
        repoPath: '/x/r',
        name: 'r',
        private: false,
      );
      expect(exec.calls.single, ['gh', 'repo', 'create', 'r', '--public']);
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

  group('resolveOriginUrl (origin wiring)', () {
    test('gh: the create output URL is the primary source — no view lookup '
        'is even issued', () async {
      exec.results.add(_ok('https')); // gh config get git_protocol
      final r = await gh.resolveOriginUrl(
        repoPath: '/x/r',
        name: 'r',
        createOutput: 'https://github.com/mac/r\n',
      );
      expect(r.url, 'https://github.com/mac/r.git');
      expect(
        exec.calls,
        hasLength(1),
        reason: 'zero API round trips beyond the protocol probe',
      );
      expect(exec.calls.single, [
        'gh',
        'config',
        'get',
        'git_protocol',
        '-h',
        'github.com',
      ]);
    });

    test('gh: https protocol returns the web URL with a .git suffix', () async {
      exec.results.add(_ok('https')); // gh config get git_protocol
      exec.results.add(
        _ok(
          '{"url":"https://github.com/mac/r","sshUrl":"git@github.com:mac/r.git"}',
        ),
      ); // gh repo view
      final r = await gh.resolveOriginUrl(repoPath: '/x/r', name: 'r');
      expect(r.url, 'https://github.com/mac/r.git');
      expect(exec.calls[0], [
        'gh',
        'config',
        'get',
        'git_protocol',
        '-h',
        'github.com',
      ]);
      expect(exec.calls[1], [
        'gh',
        'repo',
        'view',
        'r',
        '--json',
        'url,sshUrl',
      ]);
    });

    test('gh: ssh protocol prefers the lookup SSH URL over the create-output '
        'https URL', () async {
      exec.results.add(_ok('ssh'));
      exec.results.add(
        _ok(
          '{"url":"https://github.com/mac/r","sshUrl":"git@github.com:mac/r.git"}',
        ),
      );
      final r = await gh.resolveOriginUrl(
        repoPath: '/x/r',
        name: 'r',
        createOutput: 'https://github.com/mac/r\n',
      );
      expect(r.url, 'git@github.com:mac/r.git');
    });

    test('gh: ssh protocol with a dead lookup still falls back to the '
        'create-output https URL — a working origin beats none', () async {
      exec.results.add(_ok('ssh'));
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'not found',
      );
      final r = await gh.resolveOriginUrl(
        repoPath: '/x/r',
        name: 'r',
        createOutput: 'https://github.com/mac/r\n',
        retries: 0,
      );
      expect(r.url, 'https://github.com/mac/r.git');
      expect(
        r.detail,
        contains('not found'),
        reason: 'the fallback still reports why the lookup failed',
      );
    });

    test('gh: a GHE host rides GH_HOST on both probes', () async {
      exec.results.add(_ok('https'));
      exec.results.add(
        _ok(
          '{"url":"https://ghe.corp/mac/r","sshUrl":"git@ghe.corp:mac/r.git"}',
        ),
      );
      await gh.resolveOriginUrl(
        repoPath: '/x/r',
        name: 'r',
        host: 'ghe.corp.example',
      );
      expect(exec.envs[0], {'GH_HOST': 'ghe.corp.example'});
      expect(exec.envs[1], {'GH_HOST': 'ghe.corp.example'});
    });

    test(
      'gh: total failure yields a null URL and a diagnostic trail',
      () async {
        exec.next = const SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'HTTP 404: Not Found',
        );
        final r = await gh.resolveOriginUrl(
          repoPath: '/x/r',
          name: 'r',
          retries: 0,
        );
        expect(r.url, isNull);
        expect(
          r.detail,
          contains('HTTP 404'),
          reason: 'a live failure must say WHY, not just that it failed',
        );
      },
    );

    test('glab: the create output ✓-line is the primary source', () async {
      exec.results.add(_ok('')); // glab config get git_protocol (unset)
      final r = await glab.resolveOriginUrl(
        repoPath: '/x/r',
        name: 'r',
        createOutput:
            '✓ Created project on GitLab: Mac / r - '
            'https://gitlab.corp.example/mac/r\n',
      );
      expect(r.url, 'https://gitlab.corp.example/mac/r.git');
      expect(
        exec.calls,
        hasLength(1),
        reason: 'zero API round trips beyond the protocol probe',
      );
      // The host flag MUST be --host: glab's -h means --help (exits 0
      // printing help text — a silent live trap).
      expect(exec.calls.single, [
        'glab',
        'config',
        'get',
        'git_protocol',
        '--host',
        'gitlab.com',
      ]);
    });

    test(
      'glab: a bare name resolves the user namespace, then the project URL',
      () async {
        exec.results.add(_ok('')); // protocol probe (unset → https)
        exec.results.add(
          _ok('$_glabHeaders{"username":"mac"}'),
        ); // glab api user
        exec.results.add(
          _ok(
            '$_glabHeaders{"http_url_to_repo":"https://gitlab.com/mac/r.git"}',
          ),
        ); // glab api projects
        final r = await glab.resolveOriginUrl(repoPath: '/x/r', name: 'r');
        expect(r.url, 'https://gitlab.com/mac/r.git');
        expect(exec.calls[1], ['glab', 'api', 'user', '-i']);
        expect(exec.calls[2], ['glab', 'api', 'projects/mac%2Fr', '-i']);
      },
    );

    test('glab: ssh protocol picks ssh_url_to_repo', () async {
      exec.results.add(_ok('ssh'));
      exec.results.add(_ok('$_glabHeaders{"username":"mac"}'));
      exec.results.add(
        _ok(
          '$_glabHeaders{"http_url_to_repo":"https://gitlab.com/mac/r.git",'
          '"ssh_url_to_repo":"git@gitlab.com:mac/r.git"}',
        ),
      );
      final r = await glab.resolveOriginUrl(repoPath: '/x/r', name: 'r');
      expect(r.url, 'git@gitlab.com:mac/r.git');
    });

    test('glab: a group path skips the user lookup and is %2F-encoded', () async {
      exec.results.add(_ok('')); // protocol probe
      exec.results.add(
        _ok(
          '$_glabHeaders{"http_url_to_repo":"https://gitlab.com/grp/sub/r.git"}',
        ),
      );
      final r = await glab.resolveOriginUrl(
        repoPath: '/x/r',
        name: 'grp/sub/r',
      );
      expect(exec.calls[1], ['glab', 'api', 'projects/grp%2Fsub%2Fr', '-i']);
      expect(r.url, 'https://gitlab.com/grp/sub/r.git');
    });

    test(
      'glab: total failure yields a null URL and a diagnostic trail',
      () async {
        exec.next = const SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: '401 Unauthorized',
        );
        final r = await glab.resolveOriginUrl(
          repoPath: '/x/r',
          name: 'r',
          retries: 0,
        );
        expect(r.url, isNull);
        expect(r.detail, contains('401'));
      },
    );
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
        GlabService.cloneArgv(pathWithNamespace: 'group/proj', dirName: 'proj'),
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
