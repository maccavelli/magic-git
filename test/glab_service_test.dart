// Test-local fixture names intentionally mirror their command-line concepts.
// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

void main() {
  const _repo = '/repo';
  const _host = 'gitlab.example.com';
  const _notDefaultHost = 'gitlab.example.com';

  GlabService _svc(MockExecutor e) =>
      GlabService(e)..debugOriginHostOverride = 'gitlab.com';

  SSHCommandResult _ok({String stdout = '', String stderr = ''}) =>
      SSHCommandResult(exitCode: 0, stdout: stdout, stderr: stderr);

  SSHCommandResult _fail({int exitCode = 1, String stderr = ''}) =>
      SSHCommandResult(exitCode: exitCode, stdout: '', stderr: stderr);

  String _withHeaders(String body, {int status = 200}) =>
      'HTTP/2.0 $status\r\n\r\n$body';

  // ---------------------------------------------------------------------------
  // Static utilities
  // ---------------------------------------------------------------------------
  group('static utilities', () {
    test('hostEnv returns null for gitlab.com', () {
      expect(GlabService.hostEnv('gitlab.com'), isNull);
    });

    test('hostnameFlag is empty for null, blank, and gitlab.com', () {
      expect(GlabService.hostnameFlag(null), isEmpty);
      expect(GlabService.hostnameFlag(''), isEmpty);
      expect(GlabService.hostnameFlag('  '), isEmpty);
      expect(GlabService.hostnameFlag('gitlab.com'), isEmpty);
    });

    test('hostnameFlag returns --hostname for a self-hosted instance', () {
      expect(GlabService.hostnameFlag('gitlab.example.com'), [
        '--hostname',
        'gitlab.example.com',
      ]);
    });

    test('host extra env is null for a null or gitlab.com host', () {
      final service = _svc(MockExecutor());
      expect(service.debugHostExtraEnv(null), isNull);
      expect(service.debugHostExtraEnv('gitlab.com'), isNull);
      expect(service.debugHostExtraEnv('gitlab.example.com'), {
        'GITLAB_HOST': 'gitlab.example.com',
        'GITLAB_URI': 'gitlab.example.com',
      });
    });

    test('hostEnv returns env map for non-default host', () {
      expect(GlabService.hostEnv(_notDefaultHost), {
        'GITLAB_HOST': _notDefaultHost,
        'GITLAB_URI': _notDefaultHost,
      });
    });

    test('cloneArgv returns correct argv', () {
      expect(
        GlabService.cloneArgv(
          pathWithNamespace: 'group/project',
          dirName: 'my-project',
        ),
        [
          'glab',
          'repo',
          'clone',
          'group/project',
          'my-project',
          '--',
          '--progress',
        ],
      );
    });

    test('parseHttpStatus returns status code from header', () {
      expect(GlabService.parseHttpStatus('HTTP/2.0 200\r\n\r\n{}'), 200);
      expect(GlabService.parseHttpStatus('HTTP/1.1 404 Not Found\r\n'), 404);
      expect(GlabService.parseHttpStatus('HTTP/2.0 500\r\n'), 500);
    });

    test('parseHttpStatus returns null when no status line', () {
      expect(GlabService.parseHttpStatus('{}'), isNull);
      expect(GlabService.parseHttpStatus(''), isNull);
    });

    test('bodyAfterHeaders strips leading headers', () {
      const output = 'HTTP/2.0 200\r\n\r\n{"key": "value"}';
      expect(GlabService.bodyAfterHeaders(output), '{"key": "value"}');
    });

    test('bodyAfterHeaders returns full output when no header separator', () {
      const output = '{"key": "value"}';
      expect(GlabService.bodyAfterHeaders(output), output);
    });

    test('graphqlArgs builds correct args with variables', () {
      final args = GlabService.graphqlArgs(
        'query { project }',
        variables: {'path': 'my/project'},
      );
      expect(args[0], 'glab');
      expect(args[1], 'api');
      expect(args[2], 'graphql');
      expect(args[3], '-f');
      expect(args[4], 'query=query { project }');
      expect(args[5], '-f');
      expect(args[6], 'path=my/project');
    });

    test('graphqlArgs handles empty variables', () {
      final args = GlabService.graphqlArgs('query { project }');
      expect(args.length, 5);
    });

    test('projectPathFromRemote delegates', () {
      final result = GlabService.projectPathFromRemote(
        'git@gitlab.com:group/project.git',
      );
      expect(result, 'group/project');
    });

    test('projectPathFromRemote returns null for unparseable URL', () {
      expect(GlabService.projectPathFromRemote('not-a-url'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // loginWithToken
  // ---------------------------------------------------------------------------
  group('loginWithToken', () {
    test('throws on blank token', () async {
      final executor = MockExecutor();
      final service = _svc(executor);

      expect(
        () => service.loginWithToken(_repo, '  '),
        throwsA(isA<GlabException>()),
      );
      expect(executor.calls, isEmpty);
    });

    test('resolves host and calls loginWithTokenHost', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('remote')) {
            return _ok(stdout: 'origin\tgit@$_host:group/project.git');
          }
          if (call.gitArgs.contains('login')) {
            return _ok();
          }
          if (call.gitArgs.contains('api user')) {
            return _ok(stdout: '{"username": "testuser"}');
          }
          if (call.gitArgs.contains('config')) {
            return _ok();
          }
          return _ok();
        },
      );
      final service = _svc(executor);

      await service.loginWithToken(_repo, 'valid_token');

      expect(executor.calls.length, greaterThanOrEqualTo(2));
      expect(executor.calls.first.gitArgs, contains('remote'));
      expect(executor.calls.any((c) => c.gitArgs.contains('login')), isTrue);
    });

    test('throws when origin remote has no parseable host', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: 'origin\t'),
      );
      final service = _svc(executor);

      expect(
        () => service.loginWithToken(_repo, 'valid_token'),
        throwsA(isA<GlabException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // loginWithTokenHost
  // ---------------------------------------------------------------------------
  group('loginWithTokenHost', () {
    test('throws on blank token', () async {
      final executor = MockExecutor();
      final service = _svc(executor);

      await expectLater(
        () => service.loginWithTokenHost(host: _host, token: '  '),
        throwsA(isA<GlabException>()),
      );
    });

    test('success executes login and records username', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('login')) return _ok();
          if (call.gitArgs.contains('api user')) {
            return _ok(stdout: '{"username": "testuser"}');
          }
          if (call.gitArgs.contains('config')) return _ok();
          return _ok();
        },
      );
      final service = _svc(executor);
      await service.loginWithTokenHost(host: _host, token: 'valid_token');

      expect(
        executor.calls.firstWhere((c) => c.gitArgs.contains('login')).stdin,
        'valid_token',
      );
    });

    test('throws on login failure', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('login')) {
            return _fail(stderr: 'auth error');
          }
          return _ok();
        },
      );
      final service = _svc(executor);

      expect(
        () => service.loginWithTokenHost(host: _host, token: 'valid_token'),
        throwsA(isA<GlabException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // listRepos
  // ---------------------------------------------------------------------------
  group('listRepos', () {
    test('returns parsed list of ForgeRepoSummary', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(
          stdout: _withHeaders('''[
          {"path_with_namespace": "user/project1", "visibility": "public", "web_url": "https://example.com/p1"},
          {"path_with_namespace": "user/project2", "visibility": "private", "web_url": "https://example.com/p2"}
        ]'''),
        ),
      );
      final service = _svc(executor);
      final repos = await service.listRepos(cwd: _repo, host: _host);

      expect(repos.length, 2);
      expect(repos[0].slug, 'user/project1');
      expect(repos[1].slug, 'user/project2');
      expect(repos[1].isPrivate, isTrue);
    });

    test('throws on malformed response', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: _withHeaders('{"not": "a list"}')),
      );
      final service = _svc(executor);

      expect(
        () => service.listRepos(cwd: _repo, host: _host),
        throwsA(isA<GlabException>()),
      );
    });

    test('passes hostEnv for non-default host', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: _withHeaders('[]')),
      );
      final service = _svc(executor);
      await service.listRepos(cwd: _repo, host: _notDefaultHost);

      expect(
        executor.calls.first.extraEnv,
        containsPair('GITLAB_HOST', _notDefaultHost),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // createRepoInExisting
  // ---------------------------------------------------------------------------
  group('createRepoInExisting', () {
    test('returns result on success', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: '✓ Created project on GitLab: … - https://example.com/p',
        ),
      );
      final service = _svc(executor);

      final result = await service.createRepoInExisting(
        repoPath: _repo,
        name: 'new-project',
        private: true,
        host: _host,
      );
      expect(result.isSuccess, isTrue);
      expect(result.stdout, contains('Created project'));
    });

    test('throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.createRepoInExisting(
          repoPath: _repo,
          name: 'new-project',
          private: false,
          host: _host,
        ),
        throwsA(isA<GlabException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // api
  // ---------------------------------------------------------------------------
  group('api', () {
    test('GET without paginate includes -i', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: _withHeaders('{"message": "ok"}')),
      );
      final service = _svc(executor);

      await service.api(_repo, 'projects/:id', method: 'GET');
      expect(executor.calls.first.gitArgs, contains('-i'));
      expect(executor.calls.first.lane, ExecLane.read);
    });

    test('GET with paginate omits -i', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: '[{"id": 1}]'),
      );
      final service = _svc(executor);

      await service.api(_repo, 'projects/:id/pipelines', paginate: true);
      expect(executor.calls.first.gitArgs, contains('--paginate'));
      expect(executor.calls.first.gitArgs, isNot(contains('-i')));
    });

    test('POST uses sync lane', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: _withHeaders('{"message": "ok"}')),
      );
      final service = _svc(executor);

      await service.api(_repo, 'projects/:id/merge', method: 'PUT');
      expect(executor.calls.first.lane, ExecLane.sync);
    });

    test('GET with fields passes -f args', () async {
      final executor = MockExecutor(
        onExecute: (call) => _ok(stdout: _withHeaders('[{"id": 1}]')),
      );
      final service = _svc(executor);

      await service.api(
        _repo,
        'projects/:id/pipelines',
        fields: ['per_page=10', 'state=opened'],
      );
      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['-f', 'per_page=10', '-f', 'state=opened']));
    });

    test('throws on HTTP 4xx status from headers', () async {
      final executor = MockExecutor(
        onExecute: (_) =>
            _ok(stdout: _withHeaders('{"error": "not found"}', status: 404)),
      );
      final service = _svc(executor);

      expect(
        () => service.api(_repo, 'projects/:id'),
        throwsA(isA<GlabException>()),
      );
    });

    test('throws on non-zero exit without headers', () async {
      final executor = MockExecutor(
        onExecute: (_) => _fail(exitCode: 1, stderr: 'error'),
      );
      final service = _svc(executor);

      expect(
        () => service.api(_repo, 'projects/:id/pipelines', paginate: true),
        throwsA(isA<GlabException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // mergeRequests (pagination)
  // ---------------------------------------------------------------------------
  group('mergeRequests', () {
    test('returns empty list from empty JSON array', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '[]'));
      final service = _svc(executor);
      final mrs = await service.mergeRequests(_repo);
      expect(mrs, isEmpty);
    });

    test('parses a batch of merge requests', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: '''[
          {"iid": 1, "title": "MR 1", "source_branch": "feature1", "target_branch": "main", "web_url": "https://example.com/1"},
          {"iid": 2, "title": "MR 2", "source_branch": "feature2", "target_branch": "main", "web_url": "https://example.com/2"}
        ]''',
        ),
      );
      final service = _svc(executor);
      final mrs = await service.mergeRequests(_repo, perPage: 30);
      expect(mrs.length, 2);
      expect(mrs[0].iid, 1);
      expect(mrs[1].title, 'MR 2');
    });

    test('walks pages when batch equals perPage', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (_) {
          callCount++;
          // Return a short page on the second call to stop the walk
          if (callCount > 1) return _ok(stdout: '[{"iid": 99}]');
          return _ok(stdout: '[{"iid": 1}, {"iid": 2}]');
        },
      );
      final service = _svc(executor);
      final mrs = await service.mergeRequests(_repo, perPage: 2);
      // First page returned 2 (== perPage), second page returned 1 (< perPage) → stops
      expect(mrs.length, 3);
      expect(callCount, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // pipelines
  // ---------------------------------------------------------------------------
  group('pipelines', () {
    test('single page returns pipelines list', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: _withHeaders('''[
          {"id": 1, "status": "success", "ref": "main", "sha": "abc123", "web_url": "https://example.com/1"}
        ]'''),
        ),
      );
      final service = _svc(executor);
      final pipes = await service.pipelines(_repo);
      expect(pipes.length, 1);
      expect(pipes[0].id, 1);
    });

    test('allHistory walks pages', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (_) {
          callCount++;
          if (callCount > 1) return _ok(stdout: _withHeaders('[]'));
          return _ok(stdout: _withHeaders('[{"id": 1}]'));
        },
      );
      final service = _svc(executor);
      final pipes = await service.pipelines(
        _repo,
        allHistory: true,
        perPage: 100,
      );
      expect(pipes.length, 1);
    });

    test('empty response yields empty list', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('[]')),
      );
      final service = _svc(executor);
      expect(await service.pipelines(_repo), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // jobs (page walk)
  // ---------------------------------------------------------------------------
  group('jobs', () {
    test('returns jobs for a pipeline id', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: _withHeaders('''[
          {"id": 10, "name": "build", "stage": "build", "status": "success"}
        ]'''),
        ),
      );
      final service = _svc(executor);
      final js = await service.jobs(_repo, 42);
      expect(js.length, 1);
      expect(js[0].id, 10);
    });

    test('walks pages until short page', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (_) {
          callCount++;
          if (callCount > 1) return _ok(stdout: _withHeaders('[]'));
          return _ok(
            stdout: _withHeaders(
              '[{"id": 1, "name": "build", "stage": "s", "status": "ok"}]',
            ),
          );
        },
      );
      final service = _svc(executor);
      final js = await service.jobs(_repo, 42);
      expect(js.length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // resolveOriginUrl
  // ---------------------------------------------------------------------------
  group('resolveOriginUrl', () {
    test('from create output when protocol is https', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'https');
          }
          return _ok();
        },
      );
      final service = _svc(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo,
        name: 'project',
        host: _host,
        createOutput:
            '✓ Created project on GitLab: group/project - https://gitlab.example.com/group/project',
      );
      // forgeUrlFromCreateOutput appends .git
      expect(result.url, 'https://gitlab.example.com/group/project.git');
      expect(result.detail, contains('create output'));
    });

    test('SSH protocol falls through to API lookup', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'ssh');
          }
          if (call.gitArgs.length > 2 && call.gitArgs[2] == 'user') {
            return _ok(stdout: _withHeaders('{"username": "myuser"}'));
          }
          if (call.gitArgs.length > 2 &&
              call.gitArgs[2].startsWith('projects/')) {
            callCount++;
            if (callCount == 1) {
              return _ok(
                stdout: _withHeaders(
                  '{"http_url_to_repo": "https://example.com/p", "ssh_url_to_repo": "ssh://git@example.com/p"}',
                ),
              );
            }
            return _ok();
          }
          return _ok();
        },
      );
      final service = _svc(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo,
        name: 'project',
        host: _host,
        createOutput:
            '✓ Created project on GitLab: group/project - https://gitlab.example.com/group/project',
      );
      expect(result.url, 'ssh://git@example.com/p');
      expect(result.detail, contains('ssh'));
    });

    test('retries API lookup on failure', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'https');
          }
          if (call.gitArgs.length > 2 && call.gitArgs[2] == 'user') {
            return _ok(stdout: _withHeaders('{"username": "myuser"}'));
          }
          if (call.gitArgs.length > 2 &&
              call.gitArgs[2].startsWith('projects/')) {
            callCount++;
            if (callCount < 2) {
              return _ok(stdout: _withHeaders('{}', status: 500));
            }
            return _ok(
              stdout: _withHeaders(
                '{"http_url_to_repo": "https://example.com/p"}',
              ),
            );
          }
          return _ok();
        },
      );
      final service = _svc(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo,
        name: 'project',
        host: _host,
      );
      expect(result.url, 'https://example.com/p');
    });

    test('returns null URL when all sources fail', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'https');
          }
          if (call.gitArgs.length > 2 && call.gitArgs[2] == 'user') {
            return _ok(stdout: _withHeaders('{}'));
          }
          return _ok();
        },
      );
      final service = _svc(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo,
        name: 'project',
        host: _host,
      );
      expect(result.url, isNull);
    });

    test('group path (contains /) skips user lookup', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'https');
          }
          if (call.gitArgs.length > 2 &&
              call.gitArgs[2].startsWith('projects/')) {
            return _ok(
              stdout: _withHeaders(
                '{"http_url_to_repo": "https://example.com/group/project"}',
              ),
            );
          }
          return _ok();
        },
      );
      final service = _svc(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo,
        name: 'group/subgroup/project',
        host: _host,
      );
      expect(result.url, 'https://example.com/group/project');
      // Should not have called api user — check index 2 of each call
      expect(
        executor.calls.where(
          (c) => c.gitArgs.length > 2 && c.gitArgs[2] == 'user',
        ),
        isEmpty,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // graphql
  // ---------------------------------------------------------------------------
  group('graphql', () {
    test('returns data on success', () async {
      final executor = MockExecutor(
        onExecute: (_) =>
            _ok(stdout: _withHeaders('{"data": {"project": {"id": "1"}}}')),
      );
      final service = _svc(executor);
      final data = await service.graphql(_repo, 'query { project { id } }');
      expect(data, {
        'project': {'id': '1'},
      });
    });

    test('returns partial data and sets warning when errors present', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: _withHeaders('''{
          "data": {"project": {"id": "1"}},
          "errors": [{"message": "field x not accessible"}]
        }'''),
        ),
      );
      final service = _svc(executor);
      final data = await service.graphql(_repo, 'query { project { id } }');
      expect(data, {
        'project': {'id': '1'},
      });
      expect(service.lastGraphqlWarning, contains('field x not accessible'));
    });

    test('throws on null/absent data', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: _withHeaders('{"errors": [{"message": "total failure"}]}'),
        ),
      );
      final service = _svc(executor);

      expect(
        () => service.graphql(_repo, 'query { project { id } }'),
        throwsA(isA<GlabException>()),
      );
    });

    test('resets warning before each call', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{"data": {"ok": true}}')),
      );
      final service = _svc(executor);
      service.lastGraphqlWarning = 'stale';
      await service.graphql(_repo, 'query { x }');
      expect(service.lastGraphqlWarning, isNull);
    });

    test('throws on HTTP 4xx', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('not json', status: 401)),
      );
      final service = _svc(executor);

      expect(
        () => service.graphql(_repo, 'query { x }'),
        throwsA(isA<GlabException>()),
      );
    });

    test('throws on non-JSON output', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('not json at all')),
      );
      final service = _svc(executor);

      expect(
        () => service.graphql(_repo, 'query { x }'),
        throwsA(isA<GlabException>()),
      );
    });

    test('returns empty data when decoded is non-map', () async {
      // When JSON decodes to a List<String> instead of Map, graphql returns {}
      // (the decoded is! Map check triggers early return, not a throw).
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('["a", "b"]')),
      );
      final service = _svc(executor);
      final data = await service.graphql(_repo, 'query { x }');
      expect(data, <String, dynamic>{});
    });
  });

  // ---------------------------------------------------------------------------
  // projectDashboard
  // ---------------------------------------------------------------------------
  group('projectDashboard', () {
    test('returns parsed dashboard', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('remote')) {
            return _ok(stdout: 'origin\tgit@gitlab.com:group/project.git');
          }
          return _ok(
            stdout: _withHeaders('''{
            "data": {
              "project": {
                "issues": {"count": 5, "nodes": [{"iid": 1, "title": "Bug", "state": "opened"}]},
                "labels": {"count": 3, "nodes": [{"title": "bug", "color": "#f00"}]},
                "milestones": {"nodes": [{"iid": 1, "title": "v1", "state": "active"}]},
                "releases": {"count": 2, "nodes": [{"tagName": "v1.0", "name": "v1.0", "releasedAt": "2024-01-01"}]}
              }
            }
          }'''),
          );
        },
      );
      final service = _svc(executor);
      final dash = await service.projectDashboard(_repo);
      expect(dash.issues.length, 1);
      expect(dash.issuesTotal, 5);
      expect(dash.labelsTotal, 3);
      expect(dash.releases.length, 1);
      expect(dash.warning, isNull);
    });

    test('throws when project is null', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('remote')) {
            return _ok(stdout: 'origin\tgit@gitlab.com:group/project.git');
          }
          return _ok(stdout: _withHeaders('{"data": {"project": null}}'));
        },
      );
      final service = _svc(executor);

      expect(
        () => service.projectDashboard(_repo),
        throwsA(isA<GlabException>()),
      );
    });

    test('throws when origin has no GitLab path', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: 'origin\tgit@github.com:user/repo.git'),
      );
      final service = _svc(executor);

      expect(
        () => service.projectDashboard(_repo),
        throwsA(isA<GlabException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // traceStream
  // ---------------------------------------------------------------------------
  group('traceStream', () {
    test('emits stdout chunks', () async {
      final handle = MockStreamHandle();
      final executor = MockExecutor(onStream: (_) => handle);
      final service = _svc(executor);
      final emitted = <String>[];

      service.traceStream(_repo, 42).listen(emitted.add, onError: (_) {});

      await Future<void>.delayed(Duration.zero);
      handle.emitStdout('line1\n');
      handle.emitStdout('line2\n');
      handle.close();
      handle.resolveExitCode(0);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, containsAll(['line1\n', 'line2\n']));
    });

    test('emits empty tick when no output and clean exit', () async {
      final handle = MockStreamHandle();
      final executor = MockExecutor(onStream: (_) => handle);
      final service = _svc(executor);
      final emitted = <String>[];

      service.traceStream(_repo, 42).listen(emitted.add, onError: (_) {});
      await Future<void>.delayed(Duration.zero);
      handle.close();
      handle.resolveExitCode(0);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, contains(''));
    });

    test('adds error when stderr present but no stdout', () async {
      final handle = MockStreamHandle();
      final executor = MockExecutor(onStream: (_) => handle);
      final service = _svc(executor);
      final errors = <Object>[];

      service.traceStream(_repo, 42).listen((_) {}, onError: errors.add);
      await Future<void>.delayed(Duration.zero);
      handle.emitStderr('error: not found');
      handle.close();
      handle.resolveExitCode(0);
      await Future<void>.delayed(Duration.zero);

      expect(errors, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // MR mutations
  // ---------------------------------------------------------------------------
  group('MR mutations', () {
    test('approveMergeRequest calls api POST', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.approveMergeRequest(_repo, 5);

      final call = executor.calls.first;
      expect(call.gitArgs, contains('POST'));
      expect(call.lane, ExecLane.sync); // POST sets sync lane
    });

    test('retryPipeline calls api POST', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.retryPipeline(_repo, 10);

      expect(
        executor.calls.first.gitArgs.any((a) => a.contains('retry')),
        isTrue,
      );
    });

    test('createMergeRequest succeeds', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);

      await service.createMergeRequest(
        _repo,
        sourceBranch: 'feature',
        targetBranch: 'main',
        title: 'My MR',
        description: 'desc',
        draft: true,
        squash: true,
        removeSourceBranch: true,
        reviewers: ['user1'],
        assignees: ['user2'],
        labels: ['bug'],
        milestone: 'v1',
      );
      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['--source-branch', 'feature']));
      expect(args, containsAll(['--target-branch', 'main']));
      expect(args, containsAll(['--title', 'My MR']));
      expect(args, containsAll(['--description', 'desc']));
      expect(args, contains('--draft'));
      expect(args, contains('--squash-before-merge'));
      expect(args, contains('--remove-source-branch'));
      expect(args, containsAll(['--reviewer', 'user1']));
      expect(args, containsAll(['--assignee', 'user2']));
      expect(args, containsAll(['--label', 'bug']));
      expect(args, containsAll(['--milestone', 'v1']));
    });

    test('createMergeRequest throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.createMergeRequest(
          _repo,
          sourceBranch: 'f',
          targetBranch: 'm',
          title: 't',
        ),
        throwsA(isA<GlabException>()),
      );
    });

    test('mergeMergeRequest calls api PUT', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.mergeMergeRequest(
        _repo,
        1,
        squash: true,
        removeSourceBranch: true,
      );

      final call = executor.calls.first;
      expect(call.gitArgs, contains('PUT'));
      expect(call.gitArgs, containsAll(['-f', 'squash=true']));
    });

    test('mergeMergeRequest sends sha= when provided', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.mergeMergeRequest(_repo, 1, sha: 'abcdef01');
      expect(executor.calls.first.gitArgs, containsAll(['-f', 'sha=abcdef01']));
    });

    test('mergeMergeRequest omits sha when null', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.mergeMergeRequest(_repo, 1);
      final fields = executor.calls.first.gitArgs.where(
        (a) => a.startsWith('sha='),
      );
      expect(fields, isEmpty);
    });

    test('enableMergeRequestAutoMerge sets MWPS true via REST', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.enableMergeRequestAutoMerge(
        _repo,
        3,
        sha: 'deadbeef',
        squash: true,
      );
      final args = executor.calls.first.gitArgs;
      expect(args, contains('projects/:id/merge_requests/3/merge'));
      expect(args, containsAll(['-f', 'merge_when_pipeline_succeeds=true']));
      expect(args, containsAll(['-f', 'sha=deadbeef']));
      expect(args, isNot(contains('mr')));
      expect(args, isNot(contains('glab mr merge')));
    });

    test('cancelMergeRequestAutoMerge posts cancel endpoint', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.cancelMergeRequestAutoMerge(_repo, 3);
      expect(
        executor.calls.first.gitArgs,
        contains(
          'projects/:id/merge_requests/3/cancel_merge_when_pipeline_succeeds',
        ),
      );
    });

    test('rebaseMergeRequest posts rebase endpoint', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.rebaseMergeRequest(_repo, 3);
      expect(
        executor.calls.first.gitArgs,
        contains('projects/:id/merge_requests/3/rebase'),
      );
    });

    test('repoMergePolicy parses project merge fields', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: _withHeaders('''{
            "default_branch": "develop",
            "merge_method": "ff",
            "squash_option": "always",
            "remove_source_branch_after_merge": true,
            "auto_merge_enabled": true
          }'''),
        ),
      );
      final service = _svc(executor);
      final p = await service.repoMergePolicy(_repo);
      expect(p.defaultBranch, 'develop');
      expect(p.mergeMethod, 'ff');
      expect(p.squashAlways, isTrue);
      expect(p.removeSourceBranchAfterMerge, isTrue);
    });

    test('closeMergeRequest calls api PUT with state_event=close', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.closeMergeRequest(_repo, 1);

      expect(
        executor.calls.first.gitArgs,
        containsAll(['-f', 'state_event=close']),
      );
    });

    test('reopenMergeRequest calls api PUT with state_event=reopen', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: _withHeaders('{}')),
      );
      final service = _svc(executor);
      await service.reopenMergeRequest(_repo, 1);

      expect(
        executor.calls.first.gitArgs,
        containsAll(['-f', 'state_event=reopen']),
      );
    });

    test('setMergeRequestDraft sets draft flag', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.setMergeRequestDraft(_repo, 1, draft: true);

      expect(executor.calls.first.gitArgs, contains('--draft'));
    });

    test('setMergeRequestDraft clears draft flag', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.setMergeRequestDraft(_repo, 1, draft: false);

      expect(executor.calls.first.gitArgs, contains('--ready'));
    });

    test('setMergeRequestDraft throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.setMergeRequestDraft(_repo, 1, draft: true),
        throwsA(isA<GlabException>()),
      );
    });

    test('listMergeRequestNotes skips system notes', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout:
              '[{"id":1,"system":true,"body":"joined","author":{"username":"bot"}},'
              '{"id":2,"system":false,"body":"Please rebase",'
              '"author":{"username":"sam"},"created_at":"2026-08-02T00:00:00Z"}]',
        ),
      );
      final service = _svc(executor);
      final comments = await service.listMergeRequestNotes(_repo, 7);

      expect(
        executor.calls.first.gitArgs,
        contains('projects/:fullpath/merge_requests/7/notes'),
      );
      expect(comments, hasLength(1));
      expect(comments.single.author, 'sam');
      expect(comments.single.body, 'Please rebase');
    });

    test('commentOnMergeRequest sends message', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.commentOnMergeRequest(_repo, 1, 'Nice work');

      expect(
        executor.calls.first.gitArgs,
        containsAll(['--message', 'Nice work']),
      );
    });

    test('commentOnMergeRequest throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.commentOnMergeRequest(_repo, 1, 'text'),
        throwsA(isA<GlabException>()),
      );
    });

    test('editMergeRequest passes title and description', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.editMergeRequest(
        _repo,
        1,
        title: 'New title',
        description: 'New desc',
      );

      expect(
        executor.calls.first.gitArgs,
        containsAll(['--title', 'New title']),
      );
      expect(
        executor.calls.first.gitArgs,
        containsAll(['--description', 'New desc']),
      );
    });

    test('editMergeRequest omits null fields', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.editMergeRequest(_repo, 1, title: 'Only title');

      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['--title', 'Only title']));
      expect(args, isNot(contains('--description')));
    });

    test('editMergeRequest throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.editMergeRequest(_repo, 1, title: 't'),
        throwsA(isA<GlabException>()),
      );
    });

    test('checkoutMergeRequest uses exclusive lane', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.checkoutMergeRequest(_repo, 1);

      expect(executor.calls.first.lane, ExecLane.exclusive);
    });

    test('checkoutMergeRequest throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.checkoutMergeRequest(_repo, 1),
        throwsA(isA<GlabException>()),
      );
    });

    test('mergeRequestDetail returns sha and detailed_merge_status', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: '''{
            "iid": 17,
            "title": "MR",
            "state": "opened",
            "source_branch": "feat",
            "target_branch": "main",
            "web_url": "https://example/mr/17",
            "sha": "abcdef0123456789abcdef0123456789abcdef01",
            "detailed_merge_status": "mergeable",
            "description": "hello"
          }''',
        ),
      );
      final service = _svc(executor);
      final mr = await service.mergeRequestDetail(_repo, 17);
      expect(mr.iid, 17);
      expect(mr.sha, startsWith('abcdef01'));
      expect(mr.detailedMergeStatus, 'mergeable');
      expect(executor.calls.first.gitArgs, containsAll(['mr', 'view', '17']));
    });

    test('mergeRequestFields returns title and description', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: '{"title": "MR Title", "description": "MR Desc", "iid": 1}',
        ),
      );
      final service = _svc(executor);
      final fields = await service.mergeRequestFields(_repo, 1);

      expect(fields.title, 'MR Title');
      expect(fields.description, 'MR Desc');
    });

    test('mergeRequestFields throws on non-map response', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '["not", "a", "map"]'),
      );
      final service = _svc(executor);

      expect(
        () => service.mergeRequestFields(_repo, 1),
        throwsA(isA<GlabException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Issue mutations
  // ---------------------------------------------------------------------------
  group('Issue mutations', () {
    test('listIssues returns parsed issues', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: '''[
          {"iid": 1, "title": "Bug", "state": "opened"},
          {"iid": 2, "title": "Feature", "state": "opened"}
        ]''',
        ),
      );
      final service = _svc(executor);
      final issues = await service.listIssues(_repo);
      expect(issues.length, 2);
      expect(issues[0].id, 1);
    });

    test('listIssues allHistory walks pages', () async {
      // Return 30 items on first page (== perPage) to trigger page walk
      // then return empty on second page to stop.
      final page1 = List.generate(
        30,
        (i) => '{"iid": ${i + 1}, "title": "Bug $i"}',
      ).join(',\n');
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (_) {
          callCount++;
          if (callCount > 1) return _ok(stdout: '[]');
          return _ok(stdout: '[$page1]');
        },
      );
      final service = _svc(executor);
      final issues = await service.listIssues(_repo, allHistory: true);
      expect(issues.length, 30);
      expect(callCount, 2);
    });

    test('issueDetail returns parsed issue from JSON object', () async {
      final executor = MockExecutor(
        onExecute: (_) =>
            _ok(stdout: '{"iid": 5, "title": "Detail", "description": "body"}'),
      );
      final service = _svc(executor);
      final issue = await service.issueDetail(_repo, 5);
      expect(issue.id, 5);
      expect(issue.title, 'Detail');
    });

    test('issueDetail throws on non-map response', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '"just a string"'),
      );
      final service = _svc(executor);

      expect(
        () => service.issueDetail(_repo, 1),
        throwsA(isA<GlabException>()),
      );
    });

    test('listMilestones returns milestones via api', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(
          stdout: _withHeaders('''[
          {"iid": 1, "title": "v1.0", "state": "active"}
        ]'''),
        ),
      );
      final service = _svc(executor);
      final milestones = await service.listMilestones(_repo);
      expect(milestones.length, 1);
      expect(milestones[0].title, 'v1.0');
    });

    test('createIssue passes args', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.createIssue(
        _repo,
        title: 'Bug',
        description: 'details',
        labels: ['bug'],
        assignees: ['user1'],
        milestone: 'v1',
      );
      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['--title', 'Bug']));
      expect(args, containsAll(['--description', 'details']));
      expect(args, containsAll(['--label', 'bug']));
      expect(args, containsAll(['--assignee', 'user1']));
      expect(args, containsAll(['--milestone', 'v1']));
    });

    test('createIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.createIssue(_repo, title: 't'),
        throwsA(isA<GlabException>()),
      );
    });

    test('closeIssue calls glab issue close', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.closeIssue(_repo, 1);

      expect(
        executor.calls.first.gitArgs,
        containsAll(['issue', 'close', '1']),
      );
    });

    test('closeIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(() => service.closeIssue(_repo, 1), throwsA(isA<GlabException>()));
    });

    test('reopenIssue calls glab issue reopen', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.reopenIssue(_repo, 1);

      expect(
        executor.calls.first.gitArgs,
        containsAll(['issue', 'reopen', '1']),
      );
    });

    test('reopenIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.reopenIssue(_repo, 1),
        throwsA(isA<GlabException>()),
      );
    });

    test('commentOnIssue sends message', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.commentOnIssue(_repo, 1, 'Comment body');

      expect(
        executor.calls.first.gitArgs,
        containsAll(['issue', 'note', '1', '--message', 'Comment body']),
      );
    });

    test('commentOnIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.commentOnIssue(_repo, 1, 'text'),
        throwsA(isA<GlabException>()),
      );
    });

    test('editIssue passes title and description', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.editIssue(
        _repo,
        1,
        title: 'New title',
        description: 'New desc',
      );

      expect(
        executor.calls.first.gitArgs,
        containsAll(['issue', 'update', '1']),
      );
      expect(
        executor.calls.first.gitArgs,
        containsAll(['--title', 'New title']),
      );
    });

    test('editIssue omits null fields', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = _svc(executor);
      await service.editIssue(_repo, 1, title: 'Only title');

      expect(executor.calls.first.gitArgs, isNot(contains('--description')));
    });

    test('editIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = _svc(executor);

      expect(
        () => service.editIssue(_repo, 1, title: 't'),
        throwsA(isA<GlabException>()),
      );
    });
  });
}
