import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Captures argv/stdin/env and hands back queued results (in order) so multi-
/// call flows (login, polling) can be exercised without touching SSH.
class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<String?> stdins = [];
  final List<Map<String, String>?> envs = [];
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
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

void main() {
  group('GhService list calls', () {
    late _FakeExecutor exec;
    late GhService gh;

    setUp(() {
      exec = _FakeExecutor();
      gh = GhService(exec);
    });

    test('pullRequests requests the right --json fields, open state, limit', () async {
      exec.next = _ok('[]');
      await gh.pullRequests('/repo');
      final argv = exec.calls.single;
      expect(argv.take(3), ['gh', 'pr', 'list']);
      expect(argv, containsAllInOrder(['--state', 'open']));
      expect(argv, containsAllInOrder(['--limit', '600']));
      final jsonIdx = argv.indexOf('--json');
      expect(jsonIdx, greaterThanOrEqualTo(0));
      final fields = argv[jsonIdx + 1];
      for (final f in [
        'number',
        'title',
        'state',
        'isDraft',
        'headRefName',
        'baseRefName',
        'author',
        'url',
      ]) {
        expect(fields, contains(f));
      }
    });

    test('pullRequests parses rows', () async {
      exec.next = _ok(
        '[{"number":5,"title":"t","state":"OPEN","isDraft":false,'
        '"headRefName":"feat","baseRefName":"main","author":{"login":"a"},"url":"u"}]',
      );
      final prs = await gh.pullRequests('/repo');
      expect(prs, hasLength(1));
      expect(prs.single.number, 5);
      expect(prs.single.state, 'open');
      expect(prs.single.headRefName, 'feat');
    });

    test('workflowRuns requests databaseId and status fields', () async {
      exec.next = _ok('[]');
      await gh.workflowRuns('/repo');
      final argv = exec.calls.single;
      expect(argv.take(3), ['gh', 'run', 'list']);
      final fields = argv[argv.indexOf('--json') + 1];
      for (final f in ['databaseId', 'status', 'conclusion', 'headBranch']) {
        expect(fields, contains(f));
      }
    });

    test('runJobs hits the REST jobs endpoint and reads the jobs array', () async {
      exec.next = _ok(
        '{"total_count":2,"jobs":['
        '{"id":1,"name":"build","status":"completed","conclusion":"success"},'
        '{"id":2,"name":"test","status":"in_progress","conclusion":null}]}',
      );
      final jobs = await gh.runJobs('/repo', 42);
      expect(exec.calls.single, containsAllInOrder(['gh', 'api']));
      expect(
        exec.calls.single,
        contains('repos/{owner}/{repo}/actions/runs/42/jobs'),
      );
      expect(jobs, hasLength(2));
      expect(jobs[0].runState, GhRunState.success);
      expect(jobs[1].runState, GhRunState.running);
    });

    test('runJobsStream polls until all jobs complete, then stops', () async {
      String jobsObj(String status) =>
          '{"jobs":[{"id":1,"name":"j","status":"$status","conclusion":'
          '${status == "completed" ? '"success"' : "null"}}]}';
      exec.results.addAll([
        _ok(jobsObj('in_progress')),
        _ok(jobsObj('completed')),
      ]);
      final emissions = await gh
          .runJobsStream('/repo', 7, pollInterval: Duration.zero)
          .toList();
      expect(emissions, hasLength(2));
      expect(emissions.first.single.runState, GhRunState.running);
      expect(emissions.last.single.runState, GhRunState.success);
      expect(exec.calls, hasLength(2));
    });

    test('runJobsStream gives up after sustained empty answers from a '
        'finished run instead of polling forever', () async {
      // A *completed* run that yields no jobs (deleted mid-queue, API hiccup)
      // used to poll every 3s until the view closed. Each empty poll now also
      // reads the run's own status to confirm it's terminal before counting it.
      exec.results.addAll([
        _ok('{"jobs":[]}'), _ok('{"status":"completed"}'), //
        _ok('{"jobs":[]}'), _ok('{"status":"completed"}'), //
        _ok('{"jobs":[]}'), _ok('{"status":"completed"}'), //
      ]);
      final emissions = await gh
          .runJobsStream(
            '/repo',
            7,
            pollInterval: Duration.zero,
            maxEmptyPolls: 3,
          )
          .toList();
      expect(emissions, hasLength(3));
      expect(emissions, everyElement(isEmpty));
    });

    test('runJobsStream keeps polling a queued run whose empty answers must '
        'NOT count toward the give-up cap', () async {
      // A run waiting on a busy/slow runner legitimately reports zero jobs for
      // longer than the cap; abandoning the live view then is the bug. With
      // maxEmptyPolls=2 the old code would have stopped before the jobs ever
      // appeared.
      exec.results.addAll([
        _ok('{"jobs":[]}'), _ok('{"status":"queued"}'), //
        _ok('{"jobs":[]}'), _ok('{"status":"in_progress"}'), //
        _ok('{"jobs":[{"id":1,"name":"j","status":"completed",'
            '"conclusion":"success"}]}'),
      ]);
      final emissions = await gh
          .runJobsStream(
            '/repo',
            7,
            pollInterval: Duration.zero,
            maxEmptyPolls: 2,
          )
          .toList();
      expect(emissions, hasLength(3),
          reason: 'the two queued empties did not trip the cap');
      expect(emissions.first, isEmpty);
      expect(emissions.last.single.runState, GhRunState.success);
    });

    test('runJobsStream skips a transient poll error and recovers', () async {
      // An SSH reconnect superseding the in-flight read, a one-off 5xx: the
      // live view must survive it, not die permanently.
      exec.results.addAll([
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
        _ok('{"jobs":[{"id":1,"name":"j","status":"completed",'
            '"conclusion":"success"}]}'),
      ]);
      final emissions = await gh
          .runJobsStream('/repo', 7, pollInterval: Duration.zero)
          .toList();
      expect(emissions, hasLength(1), reason: 'errored polls yield nothing');
      expect(emissions.single.single.runState, GhRunState.success);
    });

    test('runJobsStream ends with the error after a sustained failure streak',
        () async {
      exec.results.addAll([
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      ]);
      expect(
        gh
            .runJobsStream(
              '/repo',
              7,
              pollInterval: Duration.zero,
              maxConsecutiveErrors: 3,
            )
            .toList(),
        throwsA(isA<GhException>()),
      );
    });

    test('the PR list ceiling matches the GitLab paginated ceiling', () async {
      exec.next = _ok('[]');
      await gh.pullRequests('/repo');
      expect(exec.calls.single, containsAllInOrder(['--limit', '600']));
    });

    test('workflowRuns allHistory raises --limit to the full-history ceiling '
        '(= the GitLab side\'s 20 pages of 100)', () async {
      exec.next = _ok('[]');
      await gh.workflowRuns('/repo', allHistory: true);
      expect(exec.calls.single, containsAllInOrder(['--limit', '2000']));

      // The everyday fetch stays one small page.
      exec.calls.clear();
      exec.next = _ok('[]');
      await gh.workflowRuns('/repo');
      expect(exec.calls.single, containsAllInOrder(['--limit', '30']));
    });

    test('a non-array list response throws (malformed, not empty)', () async {
      exec.next = _ok('{"unexpected":"object"}');
      expect(gh.pullRequests('/repo'), throwsA(isA<GhException>()));
    });
  });

  group('GhService.ownerRepoFromRemote', () {
    test('parses scp-like origin', () {
      final slug = GhService.ownerRepoFromRemote('git@github.com:owner/repo.git');
      expect(slug?.owner, 'owner');
      expect(slug?.name, 'repo');
    });

    test('parses https origin', () {
      final slug = GhService.ownerRepoFromRemote(
        'https://github.com/owner/repo.git',
      );
      expect(slug?.owner, 'owner');
      expect(slug?.name, 'repo');
    });

    test('returns null when there is no owner/repo', () {
      expect(GhService.ownerRepoFromRemote('git@github.com:onlyone'), isNull);
      expect(GhService.ownerRepoFromRemote(''), isNull);
    });
  });

  group('GhService.graphql', () {
    late _FakeExecutor exec;
    late GhService gh;

    setUp(() {
      exec = _FakeExecutor();
      gh = GhService(exec);
    });

    test('binds each variable as its own -f field', () async {
      exec.next = _ok('{"data":{"repository":{}}}');
      await gh.graphql('/repo', 'q', variables: {'owner': 'o', 'name': 'n'});
      final argv = exec.calls.single;
      expect(argv.take(3), ['gh', 'api', 'graphql']);
      expect(argv, contains('query=q'));
      expect(argv, containsAllInOrder(['-f', 'owner=o']));
      expect(argv, containsAllInOrder(['-f', 'name=n']));
    });

    test('returns partial data and records a warning when errors ride along', () async {
      // gh may exit non-zero on a partial GraphQL failure; data must still win.
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout:
            '{"data":{"repository":{"issues":{"nodes":[]}}},'
            '"errors":[{"message":"no access to field x"}]}',
        stderr: 'gh: graphql error',
      );
      final data = await gh.graphql('/repo', 'q');
      expect(data['repository'], isA<Map<String, dynamic>>());
      expect(gh.lastGraphqlWarning, contains('no access to field x'));
    });

    test('throws when there is no usable data', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '{"errors":[{"message":"bad"}]}',
        stderr: 'gh: error',
      );
      expect(gh.graphql('/repo', 'q'), throwsA(isA<GhException>()));
    });
  });

  group('GhService.graphqlErrorMessage', () {
    test('returns null when there are no errors', () {
      expect(
        GhService.graphqlErrorMessage({
          'data': {'repository': <String, dynamic>{}},
        }),
        isNull,
      );
    });

    test('joins the messages from the errors array', () {
      final msg = GhService.graphqlErrorMessage({
        'errors': [
          {'message': 'first problem'},
          {'message': 'second problem'},
        ],
      });
      expect(msg, contains('first problem'));
      expect(msg, contains('second problem'));
    });
  });

  group('GhService mutations build correct argv', () {
    late _FakeExecutor exec;
    late GhService gh;

    setUp(() {
      exec = _FakeExecutor();
      gh = GhService(exec);
    });

    test('createPullRequest always passes --body and never opens an editor', () async {
      await gh.createPullRequest(
        '/repo',
        title: 'My PR',
        head: 'feature',
        base: 'main',
      );
      final argv = exec.calls.single;
      expect(argv.take(3), ['gh', 'pr', 'create']);
      expect(argv, containsAllInOrder(['--title', 'My PR']));
      expect(argv, containsAllInOrder(['--base', 'main']));
      expect(argv, containsAllInOrder(['--head', 'feature']));
      expect(argv, contains('--body'));
    });

    test('createPullRequest emits repeated flags for reviewers/labels + draft', () async {
      await gh.createPullRequest(
        '/repo',
        title: 't',
        head: 'h',
        base: 'b',
        body: 'desc',
        draft: true,
        reviewers: ['alice', 'bob'],
        labels: ['bug'],
        milestone: 'v2',
      );
      final argv = exec.calls.single;
      expect(argv, containsAllInOrder(['--body', 'desc']));
      expect(argv, contains('--draft'));
      expect(argv.where((a) => a == '--reviewer').length, 2);
      expect(argv, containsAllInOrder(['--reviewer', 'alice']));
      expect(argv, containsAllInOrder(['--reviewer', 'bob']));
      expect(argv, containsAllInOrder(['--label', 'bug']));
      expect(argv, containsAllInOrder(['--milestone', 'v2']));
    });

    test('approvePullRequest', () async {
      await gh.approvePullRequest('/repo', 5);
      expect(exec.calls.single, ['gh', 'pr', 'review', '5', '--approve']);
    });

    test('mergePullRequest defaults to --merge; honors squash/rebase', () async {
      await gh.mergePullRequest('/repo', 5);
      expect(exec.calls.single, ['gh', 'pr', 'merge', '5', '--merge']);
      exec.calls.clear();
      await gh.mergePullRequest('/repo', 6, method: 'squash');
      expect(exec.calls.single, ['gh', 'pr', 'merge', '6', '--squash']);
    });

    test('checkoutPullRequest', () async {
      await gh.checkoutPullRequest('/repo', 9);
      expect(exec.calls.single, ['gh', 'pr', 'checkout', '9']);
    });

    test('rerunFailedJobs re-runs only failed jobs', () async {
      await gh.rerunFailedJobs('/repo', 100);
      expect(exec.calls.single, ['gh', 'run', 'rerun', '100', '--failed']);
    });

    test('a mutation never injects a token into the environment', () async {
      await gh.mergePullRequest('/repo', 1);
      expect(exec.envs.single, isNull);
    });
  });

  group('GhService.loginWithToken', () {
    late _FakeExecutor exec;
    late GhService gh;

    setUp(() {
      exec = _FakeExecutor();
      gh = GhService(exec);
    });

    test('pipes the token via stdin, never argv, and resolves the host', () async {
      exec.results.addAll([
        _ok('git@github.com:owner/repo.git\n'), // git remote get-url origin
        _ok(''), // gh auth login
      ]);
      await gh.loginWithToken('/repo', '  ghp_secret  ');

      final loginCall = exec.calls[1];
      expect(loginCall.take(3), ['gh', 'auth', 'login']);
      expect(loginCall, containsAllInOrder(['--hostname', 'github.com']));
      expect(loginCall, contains('--with-token'));
      // The token must never appear in argv.
      expect(loginCall.any((a) => a.contains('ghp_secret')), isFalse);
      // It is piped (trimmed) via stdin.
      expect(exec.stdins[1], 'ghp_secret');
    });

    test('refuses a blank token without touching the network', () async {
      expect(gh.loginWithToken('/repo', '   '), throwsA(isA<GhException>()));
      expect(exec.calls, isEmpty);
    });
  });

  group('GhService.projectDashboard', () {
    late _FakeExecutor exec;
    late GhService gh;

    setUp(() {
      exec = _FakeExecutor();
      gh = GhService(exec);
    });

    // Real api.github.com response shape (captured from cli/cli, 2026-07).
    const payload =
        '{"data":{"repository":{'
        '"issues":{"totalCount":974,"nodes":[{"number":13881,"title":"T",'
        '"state":"OPEN","author":{"login":"bob"},'
        '"labels":{"nodes":[{"name":"needs-triage"}]}}]},'
        '"labels":{"totalCount":80,"nodes":[{"name":"bug","color":"d73a4a","description":""}]},'
        '"milestones":{"totalCount":0,"nodes":[]},'
        '"releases":{"totalCount":200,"nodes":[{"tagName":"v2.96.0",'
        '"name":"GitHub CLI 2.96.0","publishedAt":"2026-07-02T21:31:04Z"}]}}}}';

    test('parses a real-shaped payload with totals, no warning', () async {
      exec.results.addAll([
        _ok('git@github.com:owner/repo.git'),
        _ok(payload),
      ]);
      final d = await gh.projectDashboard('/repo');
      expect(d.issues.single.id, 13881);
      expect(d.issues.single.labels, ['needs-triage']);
      expect(d.issuesTotal, 974);
      expect(d.labels.single.color, '#d73a4a');
      expect(d.releasesTotal, 200);
      expect(d.releases.single.publishedDate, '2026-07-02');
      expect(d.warning, isNull);
    });

    test('carries a partial-data warning on the result', () async {
      exec.results.addAll([
        _ok('git@github.com:owner/repo.git'),
        const SSHCommandResult(
          exitCode: 1,
          stdout:
              '{"data":{"repository":{"issues":{"nodes":[]}}},'
              '"errors":[{"message":"no access to field x"}]}',
          stderr: 'gh: graphql error',
        ),
      ]);
      final d = await gh.projectDashboard('/repo');
      expect(d.warning, contains('no access to field x'));
    });

    test(
      'a null repository (NOT_FOUND) throws instead of rendering an '
      'empty dashboard',
      () async {
        // Real shape: data present, repository null, NOT_FOUND in errors[].
        exec.results.addAll([
          _ok('git@github.com:owner/repo.git'),
          const SSHCommandResult(
            exitCode: 1,
            stdout:
                '{"data":{"repository":null},"errors":[{"type":"NOT_FOUND",'
                '"message":"Could not resolve to a Repository"}]}',
            stderr: 'gh: Could not resolve to a Repository',
          ),
        ]);
        await expectLater(
          gh.projectDashboard('/repo'),
          throwsA(
            isA<GhException>().having(
              (e) => e.message,
              'message',
              contains('Could not resolve'),
            ),
          ),
        );
      },
    );

    test('queries totalCount on every connection', () {
      expect(
        RegExp('totalCount')
            .allMatches(GhService.projectDashboardQuery)
            .length,
        4,
      );
    });
  });

  group('GhService.graphql warning lifecycle', () {
    test('a clean call resets the previous warning', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.next = _ok(
        '{"data":{"repository":{}},"errors":[{"message":"partial"}]}',
      );
      await gh.graphql('/repo', 'q');
      expect(gh.lastGraphqlWarning, contains('partial'));

      exec.next = _ok('{"data":{"repository":{}}}');
      await gh.graphql('/repo', 'q');
      expect(gh.lastGraphqlWarning, isNull);
    });
  });
}
