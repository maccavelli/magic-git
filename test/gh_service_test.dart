import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

void main() {
  const _repo = '/repo';
  const _host = 'github.com';

  SSHCommandResult _ok({String stdout = '', String stderr = ''}) =>
      SSHCommandResult(exitCode: 0, stdout: stdout, stderr: stderr);

  SSHCommandResult _fail({int exitCode = 1, String stderr = ''}) =>
      SSHCommandResult(exitCode: exitCode, stdout: '', stderr: stderr);

  // ---------------------------------------------------------------------------
  // Static utilities
  // ---------------------------------------------------------------------------
  group('static utilities', () {
    test('hostEnv returns null for github.com', () {
      expect(GhService.hostEnv('github.com'), isNull);
    });

    test('hostEnv returns env map for non-default host', () {
      expect(GhService.hostEnv('git.example.com'), {'GH_HOST': 'git.example.com'});
    });

    test('cloneArgv returns correct argv', () {
      expect(
        GhService.cloneArgv(slug: 'owner/repo', dirName: 'my-repo'),
        ['gh', 'repo', 'clone', 'owner/repo', 'my-repo', '--', '--progress'],
      );
    });

    test('ownerRepoFromRemote returns owner and name', () {
      final result = GhService.ownerRepoFromRemote(
        'git@github.com:owner/repo.git',
      );
      expect(result!.owner, 'owner');
      expect(result.name, 'repo');
    });

    test('ownerRepoFromRemote returns null for unparseable URL', () {
      expect(GhService.ownerRepoFromRemote('not-a-url'), isNull);
    });

    test('fullHistoryLimit is a const', () {
      expect(GhService.fullHistoryLimit, 2000);
    });
  });

  // ---------------------------------------------------------------------------
  // loginWithToken
  // ---------------------------------------------------------------------------
  group('loginWithToken', () {
    test('throws on blank token', () async {
      final executor = MockExecutor();
      final service = GhService(executor);

      expect(
        () => service.loginWithToken(_repo, '  '),
        throwsA(isA<GhException>()),
      );
      expect(executor.calls, isEmpty);
    });

    test('resolves host and calls loginWithTokenHost', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('remote')) {
            return _ok(stdout: 'origin\tgit@github.com:owner/repo.git');
          }
          if (call.gitArgs.contains('login')) return _ok();
          return _ok();
        },
      );
      final service = GhService(executor);

      await service.loginWithToken(_repo, 'valid_token');
      expect(
        executor.calls.any((c) => c.gitArgs.contains('login')),
        isTrue,
      );
    });

    test('throws when origin remote has no parseable host', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: 'origin\t'),
      );
      final service = GhService(executor);

      expect(
        () => service.loginWithToken(_repo, 'valid_token'),
        throwsA(isA<GhException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // loginWithTokenHost
  // ---------------------------------------------------------------------------
  group('loginWithTokenHost', () {
    test('throws on blank token', () async {
      final executor = MockExecutor();
      final service = GhService(executor);

      await expectLater(
        () => service.loginWithTokenHost(host: _host, token: '  '),
        throwsA(isA<GhException>()),
      );
    });

    test('success executes login with stdin', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);

      await service.loginWithTokenHost(host: _host, token: 'valid_token');
      expect(
        executor.calls.firstWhere((c) => c.gitArgs.contains('login')).stdin,
        'valid_token',
      );
    });

    test('throws on login failure', () async {
      final executor = MockExecutor(
        onExecute: (_) => _fail(stderr: 'auth error'),
      );
      final service = GhService(executor);

      expect(
        () => service.loginWithTokenHost(host: _host, token: 'valid_token'),
        throwsA(isA<GhException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // listRepos
  // ---------------------------------------------------------------------------
  group('listRepos', () {
    test('returns parsed list of ForgeRepoSummary', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '''[
          {"nameWithOwner": "owner/repo1", "isPrivate": true, "url": "https://github.com/owner/repo1"},
          {"nameWithOwner": "owner/repo2", "isPrivate": false, "url": "https://github.com/owner/repo2"}
        ]'''),
      );
      final service = GhService(executor);
      final repos = await service.listRepos(cwd: _repo, host: _host);

      expect(repos.length, 2);
      expect(repos[0].slug, 'owner/repo1');
      expect(repos[1].isPrivate, isFalse);
    });

    test('throws on malformed response', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '{"not": "a list"}'),
      );
      final service = GhService(executor);

      expect(
        () => service.listRepos(cwd: _repo),
        throwsA(isA<GhException>()),
      );
    });

    test('passes hostEnv for non-default host', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '[]'),
      );
      final service = GhService(executor);
      await service.listRepos(cwd: _repo, host: 'git.example.com');

      expect(executor.calls.first.extraEnv, {'GH_HOST': 'git.example.com'});
    });
  });

  // ---------------------------------------------------------------------------
  // createRepoInExisting
  // ---------------------------------------------------------------------------
  group('createRepoInExisting', () {
    test('returns result on success', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: 'created'));
      final service = GhService(executor);
      final result = await service.createRepoInExisting(
        repoPath: _repo, name: 'new-repo', private: true, host: _host,
      );
      expect(result.isSuccess, isTrue);
    });

    test('throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = GhService(executor);

      expect(
        () => service.createRepoInExisting(
          repoPath: _repo, name: 'new-repo', private: false, host: _host,
        ),
        throwsA(isA<GhException>()),
      );
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
      final service = GhService(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo, name: 'repo', host: _host,
        createOutput: 'https://github.com/owner/repo',
      );
      // forgeUrlFromCreateOutput appends .git
      expect(result.url, 'https://github.com/owner/repo.git');
      expect(result.detail, contains('create output'));
    });

    test('SSH protocol falls through to gh repo view', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'ssh');
          }
          if (call.gitArgs.length > 2 &&
              call.gitArgs[1] == 'repo' &&
              call.gitArgs[2] == 'view') {
            return _ok(stdout: '{"sshUrl": "git@github.com:owner/repo.git", "url": "https://github.com/owner/repo"}');
          }
          return _ok();
        },
      );
      final service = GhService(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo, name: 'repo', host: _host,
        createOutput: 'https://github.com/owner/repo',
      );
      expect(result.url, 'git@github.com:owner/repo.git');
      expect(result.detail, contains('ssh'));
    });

    test('retries gh repo view on failure', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'https');
          }
          if (call.gitArgs.length > 2 &&
              call.gitArgs[1] == 'repo' &&
              call.gitArgs[2] == 'view') {
            callCount++;
            if (callCount < 2) return _fail(stderr: 'not found');
            return _ok(stdout: '{"url": "https://github.com/owner/repo", "sshUrl": "git@github.com:owner/repo.git"}');
          }
          return _ok();
        },
      );
      final service = GhService(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo, name: 'repo', host: _host,
      );
      expect(result.url, 'https://github.com/owner/repo.git'); // .git appended
    });

    test('returns null URL when all sources fail', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.any((a) => a.contains('config'))) {
            return _ok(stdout: 'https');
          }
          if (call.gitArgs.any((a) => a.contains('repo view'))) {
            return _fail(stderr: 'not found');
          }
          return _ok();
        },
      );
      final service = GhService(executor);
      final result = await service.resolveOriginUrl(
        repoPath: _repo, name: 'repo', host: _host,
      );
      expect(result.url, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // api
  // ---------------------------------------------------------------------------
  group('api', () {
    test('GET uses read lane', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '{"ok": true}'));
      final service = GhService(executor);

      await service.api(_repo, 'repos/owner/repo');
      expect(executor.calls.first.lane, ExecLane.read);
    });

    test('POST uses sync lane', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '{}'));
      final service = GhService(executor);

      await service.api(_repo, 'repos/owner/repo', method: 'POST');
      expect(executor.calls.first.lane, ExecLane.sync);
    });

    test('throws on non-zero exit', () async {
      final executor = MockExecutor(onExecute: (_) => _fail());
      final service = GhService(executor);

      expect(
        () => service.api(_repo, 'repos/owner/repo'),
        throwsA(isA<GhException>()),
      );
    });

    test('non-JSON output throws', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: 'not json'));
      final service = GhService(executor);

      expect(
        () => service.api(_repo, 'repos/owner/repo'),
        throwsA(isA<GhException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // pullRequests
  // ---------------------------------------------------------------------------
  group('pullRequests', () {
    test('returns empty list', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '[]'));
      final service = GhService(executor);
      expect(await service.pullRequests(_repo), isEmpty);
    });

    test('parses pull requests', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '''[
          {"number": 1, "title": "PR 1", "state": "OPEN", "headRefName": "feature", "baseRefName": "main", "url": "https://github.com/o/r/pull/1"},
          {"number": 2, "title": "PR 2", "state": "OPEN", "headRefName": "fix", "baseRefName": "main", "url": "https://github.com/o/r/pull/2", "isDraft": true}
        ]'''),
      );
      final service = GhService(executor);
      final prs = await service.pullRequests(_repo);
      expect(prs.length, 2);
      expect(prs[0].number, 1);
      expect(prs[1].draft, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // workflowRuns
  // ---------------------------------------------------------------------------
  group('workflowRuns', () {
    test('returns runs', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '''[
          {"databaseId": 10, "status": "completed", "conclusion": "success", "headBranch": "main", "workflowName": "CI", "url": "https://github.com/o/r/actions/10"}
        ]'''),
      );
      final service = GhService(executor);
      final runs = await service.workflowRuns(_repo);
      expect(runs.length, 1);
      expect(runs[0].id, 10);
    });

    test('allHistory uses fullHistoryLimit', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '[]'));
      final service = GhService(executor);
      await service.workflowRuns(_repo, allHistory: true);

      final args = executor.calls.first.gitArgs;
      final limitIndex = args.indexOf('--limit');
      expect(int.parse(args[limitIndex + 1]), GhService.fullHistoryLimit);
    });
  });

  // ---------------------------------------------------------------------------
  // runJobs
  // ---------------------------------------------------------------------------
  group('runJobs', () {
    test('returns jobs for a run', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '{"jobs": [{"id": 1, "name": "build", "status": "completed", "conclusion": "success"}]}'),
      );
      final service = GhService(executor);
      final jobs = await service.runJobs(_repo, 42);
      expect(jobs.length, 1);
      expect(jobs[0].id, 1);
    });

    test('walks pages', () async {
      var callCount = 0;
      final executor = MockExecutor(
        onExecute: (_) {
          callCount++;
          if (callCount > 1) return _ok(stdout: '{"jobs": []}');
          return _ok(stdout: '{"jobs": [{"id": 1, "name": "build", "status": "completed"}]}');
        },
      );
      final service = GhService(executor);
      final jobs = await service.runJobs(_repo, 42);
      expect(jobs.length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // runJobsStream
  // ---------------------------------------------------------------------------
  group('runJobsStream', () {
    test('yields jobs and stops when all completed', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          // _runReportsFinished endpoint (no /jobs suffix)
          if (call.gitArgs.any((a) => a == 'repos/{owner}/{repo}/actions/runs/42')) {
            return _ok(stdout: '{"status": "completed"}');
          }
          // runJobs endpoint
          return _ok(stdout: '{"jobs": [{"id": 1, "name": "build", "status": "completed", "conclusion": "success"}]}');
        },
      );
      final service = GhService(executor);
      final emitted = await service.runJobsStream(
        _repo, 42,
        pollInterval: Duration.zero,
      ).toList();
      expect(emitted.length, greaterThanOrEqualTo(1));
      expect(emitted.last.every((j) => j.status == 'completed'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // runJobLog
  // ---------------------------------------------------------------------------
  group('runJobLog', () {
    test('returns log on success', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: 'log content\nline2'),
      );
      final service = GhService(executor);
      final log = await service.runJobLog(_repo, 10);
      expect(log, 'log content\nline2');
    });

    test('throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'job not complete'));
      final service = GhService(executor);

      expect(
        () => service.runJobLog(_repo, 10),
        throwsA(isA<GhException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // graphql
  // ---------------------------------------------------------------------------
  group('graphql', () {
    test('returns data on success', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '{"data": {"repository": {"id": "1"}}}'),
      );
      final service = GhService(executor);
      final data = await service.graphql(_repo, 'query { x }');
      expect(data, {'repository': {'id': '1'}});
    });

    test('sets warning when errors present alongside data', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '''{
          "data": {"repository": {"id": "1"}},
          "errors": [{"message": "field x not accessible"}]
        }'''),
      );
      final service = GhService(executor);
      final data = await service.graphql(_repo, 'query { x }');
      expect(data, {'repository': {'id': '1'}});
      expect(service.lastGraphqlWarning, contains('field x not accessible'));
    });

    test('resets warning before each call', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '{"data": {"ok": true}}'),
      );
      final service = GhService(executor);
      service.lastGraphqlWarning = 'stale';
      await service.graphql(_repo, 'query { x }');
      expect(service.lastGraphqlWarning, isNull);
    });

    test('throws on failure when no data', () async {
      final executor = MockExecutor(
        onExecute: (_) => _fail(stderr: 'auth error'),
      );
      final service = GhService(executor);

      expect(
        () => service.graphql(_repo, 'query { x }'),
        throwsA(isA<GhException>()),
      );
    });

    test('throws on non-json output', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: 'not json'));
      final service = GhService(executor);

      expect(
        () => service.graphql(_repo, 'query { x }'),
        throwsA(isA<GhException>()),
      );
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
            return _ok(stdout: 'origin\tgit@github.com:owner/repo.git');
          }
          return _ok(stdout: '{"data": {"repository": {"issues": {"totalCount": 5, "nodes": [{"number": 1, "title": "Bug", "state": "OPEN"}]}, "labels": {"totalCount": 3, "nodes": [{"name": "bug", "color": "#f00"}]}, "milestones": {"totalCount": 1, "nodes": [{"number": 1, "title": "v1", "state": "OPEN"}]}, "releases": {"totalCount": 2, "nodes": [{"tagName": "v1.0", "name": "v1.0"}]}}}}');
        },
      );
      final service = GhService(executor);
      final dash = await service.projectDashboard(_repo);
      expect(dash.issues.length, 1);
      expect(dash.issuesTotal, 5);
      expect(dash.labelsTotal, 3);
      expect(dash.warning, isNull);
    });

    test('throws when repository is null', () async {
      final executor = MockExecutor(
        onExecute: (call) {
          if (call.gitArgs.contains('remote')) {
            return _ok(stdout: 'origin\tgit@github.com:owner/repo.git');
          }
          return _ok(stdout: '{"data": {"repository": null}, "errors": [{"message": "NOT_FOUND"}]}');
        },
      );
      final service = GhService(executor);

      expect(
        () => service.projectDashboard(_repo),
        throwsA(isA<GhException>()),
      );
    });

    test('throws when origin has no owner/repo', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: 'origin\tnot-a-url'),
      );
      final service = GhService(executor);

      expect(
        () => service.projectDashboard(_repo),
        throwsA(isA<GhException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // PR mutations
  // ---------------------------------------------------------------------------
  group('PR mutations', () {
    test('createPullRequest passes all args', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);

      await service.createPullRequest(
        _repo,
        title: 'My PR',
        head: 'feature',
        base: 'main',
        body: 'description',
        draft: true,
        reviewers: ['user1'],
        assignees: ['user2'],
        labels: ['bug'],
        milestone: 'v1',
      );
      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['--title', 'My PR']));
      expect(args, containsAll(['--base', 'main']));
      expect(args, containsAll(['--head', 'feature']));
      expect(args, containsAll(['--body', 'description']));
      expect(args, contains('--draft'));
      expect(args, containsAll(['--reviewer', 'user1']));
      expect(args, containsAll(['--assignee', 'user2']));
      expect(args, containsAll(['--label', 'bug']));
      expect(args, containsAll(['--milestone', 'v1']));
    });

    test('createPullRequest throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = GhService(executor);

      expect(
        () => service.createPullRequest(
          _repo, title: 't', head: 'h', base: 'b',
        ),
        throwsA(isA<GhException>()),
      );
    });

    test('approvePullRequest calls gh pr review --approve', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.approvePullRequest(_repo, 1);

      expect(executor.calls.first.gitArgs, containsAll(['pr', 'review', '1', '--approve']));
    });

    test('mergePullRequest uses default merge flag', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.mergePullRequest(_repo, 1);

      expect(executor.calls.first.gitArgs, contains('--merge'));
    });

    test('mergePullRequest supports squash and rebase', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.mergePullRequest(_repo, 1, method: 'squash');
      expect(executor.calls.first.gitArgs, contains('--squash'));

      await service.mergePullRequest(_repo, 2, method: 'rebase');
      expect(executor.calls.last.gitArgs, contains('--rebase'));
    });

    test('mergePullRequest with deleteBranch', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.mergePullRequest(_repo, 1, deleteBranch: true);
      expect(executor.calls.first.gitArgs, contains('--delete-branch'));
    });

    test('closePullRequest calls gh pr close', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.closePullRequest(_repo, 1);

      expect(executor.calls.first.gitArgs, containsAll(['pr', 'close', '1']));
    });

    test('reopenPullRequest calls gh pr reopen', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.reopenPullRequest(_repo, 1);

      expect(executor.calls.first.gitArgs, containsAll(['pr', 'reopen', '1']));
    });

    test('setPullRequestDraft uses --undo for draft=true', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.setPullRequestDraft(_repo, 1, draft: true);

      expect(executor.calls.first.gitArgs, contains('--undo'));
    });

    test('setPullRequestDraft omits --undo for draft=false', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.setPullRequestDraft(_repo, 1, draft: false);

      expect(executor.calls.first.gitArgs, isNot(contains('--undo')));
    });

    test('commentOnPullRequest sends body', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.commentOnPullRequest(_repo, 1, 'Nice work');

      expect(executor.calls.first.gitArgs, containsAll(['--body', 'Nice work']));
    });

    test('requestChangesOnPullRequest sends body', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.requestChangesOnPullRequest(_repo, 1, 'Needs fixes');

      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['pr', 'review', '1', '--request-changes']));
      expect(args, containsAll(['--body', 'Needs fixes']));
    });

    test('editPullRequest passes title and body', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.editPullRequest(_repo, 1, title: 'New title', body: 'New body');

      expect(executor.calls.first.gitArgs, containsAll(['--title', 'New title']));
      expect(executor.calls.first.gitArgs, containsAll(['--body', 'New body']));
    });

    test('editPullRequest omits null fields', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.editPullRequest(_repo, 1, title: 'Only title');

      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['--title', 'Only title']));
      expect(args, isNot(contains('--body')));
    });

    test('checkoutPullRequest uses exclusive lane', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.checkoutPullRequest(_repo, 1);

      expect(executor.calls.first.lane, ExecLane.exclusive);
    });

    test('pullRequestFields returns title and body', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '{"title": "PR Title", "body": "PR Body"}'),
      );
      final service = GhService(executor);
      final fields = await service.pullRequestFields(_repo, 1);

      expect(fields.title, 'PR Title');
      expect(fields.body, 'PR Body');
    });

    test('pullRequestFields throws on non-map response', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '["not", "a", "map"]'),
      );
      final service = GhService(executor);

      expect(
        () => service.pullRequestFields(_repo, 1),
        throwsA(isA<GhException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Issue mutations
  // ---------------------------------------------------------------------------
  group('Issue mutations', () {
    test('listIssues returns parsed issues', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '''[
        {"number": 1, "title": "Bug", "state": "OPEN"},
        {"number": 2, "title": "Feature", "state": "OPEN"}
      ]'''));
      final service = GhService(executor);
      final issues = await service.listIssues(_repo);
      expect(issues.length, 2);
      expect(issues[0].id, 1);
    });

    test('listIssues allHistory uses fullHistoryLimit', () async {
      final executor = MockExecutor(onExecute: (_) => _ok(stdout: '[]'));
      final service = GhService(executor);
      await service.listIssues(_repo, allHistory: true);

      final args = executor.calls.first.gitArgs;
      final limitIndex = args.indexOf('--limit');
      expect(int.parse(args[limitIndex + 1]), GhService.fullHistoryLimit);
    });

    test('issueDetail returns parsed issue', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '{"number": 5, "title": "Detail", "body": "body text", "state": "OPEN"}'),
      );
      final service = GhService(executor);
      final issue = await service.issueDetail(_repo, 5);
      expect(issue.id, 5);
      expect(issue.title, 'Detail');
      expect(issue.body, 'body text');
    });

    test('issueDetail throws on non-map response', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '"just a string"'),
      );
      final service = GhService(executor);

      expect(
        () => service.issueDetail(_repo, 1),
        throwsA(isA<GhException>()),
      );
    });

    test('listMilestones returns milestones', () async {
      final executor = MockExecutor(
        onExecute: (_) => _ok(stdout: '''[
          {"number": 1, "title": "v1.0", "state": "open"}
        ]'''),
      );
      final service = GhService(executor);
      final milestones = await service.listMilestones(_repo);
      expect(milestones.length, 1);
      expect(milestones[0].title, 'v1.0');
    });

    test('createIssue passes args', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.createIssue(
        _repo, title: 'Bug', body: 'details',
        labels: ['bug'], assignees: ['user1'], milestone: 'v1',
      );
      final args = executor.calls.first.gitArgs;
      expect(args, containsAll(['--title', 'Bug']));
      expect(args, containsAll(['--body', 'details']));
      expect(args, containsAll(['--label', 'bug']));
      expect(args, containsAll(['--assignee', 'user1']));
      expect(args, containsAll(['--milestone', 'v1']));
    });

    test('createIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = GhService(executor);

      expect(
        () => service.createIssue(_repo, title: 't'),
        throwsA(isA<GhException>()),
      );
    });

    test('closeIssue calls gh issue close', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.closeIssue(_repo, 1);

      expect(executor.calls.first.gitArgs, containsAll(['issue', 'close', '1']));
    });

    test('closeIssue throws on failure', () async {
      final executor = MockExecutor(onExecute: (_) => _fail(stderr: 'error'));
      final service = GhService(executor);

      expect(
        () => service.closeIssue(_repo, 1),
        throwsA(isA<GhException>()),
      );
    });

    test('reopenIssue calls gh issue reopen', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.reopenIssue(_repo, 1);

      expect(executor.calls.first.gitArgs, containsAll(['issue', 'reopen', '1']));
    });

    test('commentOnIssue sends body', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.commentOnIssue(_repo, 1, 'Comment body');

      expect(executor.calls.first.gitArgs, containsAll(['issue', 'comment', '1', '--body', 'Comment body']));
    });

    test('editIssue passes title and body', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.editIssue(_repo, 1, title: 'New title', body: 'New body');

      expect(executor.calls.first.gitArgs, containsAll(['issue', 'edit', '1']));
      expect(executor.calls.first.gitArgs, containsAll(['--title', 'New title']));
    });

    test('editIssue omits null fields', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.editIssue(_repo, 1, title: 'Only title');

      expect(executor.calls.first.gitArgs, isNot(contains('--body')));
    });

    test('assignIssueToMe sends @me', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.assignIssueToMe(_repo, 1);

      expect(executor.calls.first.gitArgs, containsAll(['--add-assignee', '@me']));
    });

    test('developIssueBranch uses exclusive lane', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.developIssueBranch(_repo, 1);

      expect(executor.calls.first.lane, ExecLane.exclusive);
    });

    test('rerunFailedJobs calls gh run rerun', () async {
      final executor = MockExecutor(onExecute: (_) => _ok());
      final service = GhService(executor);
      await service.rerunFailedJobs(_repo, 42);

      expect(executor.calls.first.gitArgs, containsAll(['run', 'rerun', '42', '--failed']));
    });
  });
}
