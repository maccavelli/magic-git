import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Captures argv and hands back queued results (in order) so a multi-page walk
/// can be exercised without touching SSH.
class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
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
  }) async {
    calls.add(gitArgs);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// A JSON array of [count] minimal objects, ids starting at [startId].
String _jsonRows(int count, int startId, String Function(int id) row) =>
    '[${List.generate(count, (i) => row(startId + i)).join(',')}]';

void main() {
  group('GlabService project dashboard query', () {
    test('filters issues with state, not deprecated states', () {
      expect(
        GlabService.projectDashboardQuery,
        contains('issues(state: opened'),
      );
      expect(GlabService.projectDashboardQuery, isNot(contains('states:')));
    });
  });

  group('GlabService HTTP helpers', () {
    test('parseHttpStatus reads the status line', () {
      const raw = 'HTTP/2 401\ncontent-type: application/json\n\n{"error":"x"}';
      expect(GlabService.parseHttpStatus(raw), 401);
    });

    test('bodyAfterHeaders strips header block', () {
      const raw = 'HTTP/2 200\ncontent-type: application/json\n\n[{"id":1}]';
      expect(GlabService.bodyAfterHeaders(raw), '[{"id":1}]');
    });
  });

  group('GlabService paginated REST calls', () {
    late _FakeExecutor exec;
    late GlabService glab;

    setUp(() {
      exec = _FakeExecutor();
      glab = GlabService(exec)..debugOriginHostOverride = 'gitlab.com';
    });

    test('paginated calls drop -i (which is incompatible with --paginate); '
        'non-paginated calls keep it', () async {
      // `--paginate` + `-i` interleaves a header block per page, so the
      // leading-header strip + first-status-line read only ever see page 1.
      // Exercised through api() directly: the issues()/releases() wrappers
      // that used to cover this were dead code once the Project dashboard
      // moved to one GraphQL round-trip, and were removed.
      await glab.api('/repo', 'projects/:id/issues', paginate: true);
      expect(exec.calls.single, contains('--paginate'));
      expect(
        exec.calls.single,
        isNot(contains('-i')),
        reason: 'a paginated call must not combine -i with --paginate',
      );

      // A non-paginated call still uses -i to catch a misleading exit code.
      exec.calls.clear();
      await glab.pipelines('/repo');
      expect(exec.calls.single, isNot(contains('--paginate')));
      expect(exec.calls.single, contains('-i'));
    });

    test('a non-zero glab exit with an HTTP 200 still returns the body '
        '(exit code is advisory — HTTP status is the authority)', () async {
      // glab #911: glab can exit non-zero on a perfectly good 200. The `-i`
      // path exists to see through that; the exit-code throw used to preempt it.
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout:
            'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"id":42}',
        stderr: 'glab: some advisory noise',
      );
      final decoded = await glab.api('/repo', 'projects/:id');
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded as Map)['id'], 42);
    });

    test('a non-zero glab exit with an HTTP 404 throws (real error)', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"404 Not Found"}',
        stderr: '',
      );
      expect(glab.api('/repo', 'projects/:id'), throwsA(isA<GlabException>()));
    });

    test('a non-zero glab exit with no HTTP status line still throws '
        '(truncated/transport failure)', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ssh: connection closed',
      );
      expect(glab.api('/repo', 'projects/:id'), throwsA(isA<GlabException>()));
    });

    test('graphql returns partial data despite a non-zero exit when HTTP is '
        '200 (partial-dashboard case)', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout:
            'HTTP/2.0 200 OK\r\n\r\n'
            '{"data":{"project":{"x":1}},'
            '"errors":[{"message":"no access to field y"}]}',
        stderr: 'glab: graphql error',
      );
      final data = await glab.graphql('/repo', 'q');
      expect(data['project'], isA<Map<String, dynamic>>());
      expect(glab.lastGraphqlWarning, contains('no access to field y'));
    });

    test(
      'jobs walks pages until a short page and accumulates all of them',
      () async {
        String jobRow(int id) =>
            '{"id":$id,"name":"j$id","stage":"build","status":"success"}';
        // Page 1 is full (100) → keep going; page 2 is short (5) → stop.
        exec.results.addAll([
          _ok(_jsonRows(100, 1, jobRow)),
          _ok(_jsonRows(5, 101, jobRow)),
        ]);

        final jobs = await glab.jobs('/repo', 7);

        expect(
          jobs,
          hasLength(105),
          reason: 'jobs past #100 must not be dropped',
        );
        expect(exec.calls, hasLength(2));
        expect(exec.calls[0], containsAllInOrder(['-f', 'page=1']));
        expect(exec.calls[1], containsAllInOrder(['-f', 'page=2']));
        // A manual page walk, never `--paginate` (kept bounded per selection).
        expect(exec.calls.every((c) => !c.contains('--paginate')), isTrue);
      },
    );

    test('jobs stops after a single short page (common case)', () async {
      String jobRow(int id) =>
          '{"id":$id,"name":"j$id","stage":"build","status":"failed"}';
      exec.next = _ok(_jsonRows(3, 1, jobRow));
      final jobs = await glab.jobs('/repo', 1);
      expect(jobs, hasLength(3));
      expect(exec.calls, hasLength(1));
    });

    test('mergeRequests walks pages via --page and accumulates', () async {
      String mrRow(int id) =>
          '{"iid":$id,"title":"t$id","state":"opened",'
          '"source_branch":"a","target_branch":"main","web_url":"","draft":false}';
      exec.results.addAll([
        _ok(_jsonRows(30, 1, mrRow)),
        _ok(_jsonRows(2, 31, mrRow)),
      ]);

      final mrs = await glab.mergeRequests('/repo');

      expect(mrs, hasLength(32), reason: 'MRs past the first page must show');
      expect(exec.calls, hasLength(2));
      expect(exec.calls[0], containsAllInOrder(['--page', '1']));
      expect(exec.calls[1], containsAllInOrder(['--page', '2']));
    });

    test('pipelines default is a single newest page, no walk', () async {
      String pipeRow(int id) =>
          '{"id":$id,"status":"success","ref":"main","sha":"aaa","web_url":""}';
      // A full default page must NOT trigger a second fetch — depth beyond it
      // is the "Show more" (allHistory) path's job.
      exec.next = _ok(_jsonRows(30, 1, pipeRow));

      final pipes = await glab.pipelines('/repo');

      expect(pipes, hasLength(30));
      expect(exec.calls, hasLength(1));
      expect(exec.calls.single, containsAllInOrder(['-f', 'per_page=30']));
    });

    test('pipelines allHistory walks pages of 100 until a short page', () async {
      String pipeRow(int id) =>
          '{"id":$id,"status":"success","ref":"main","sha":"aaa","web_url":""}';
      exec.results.addAll([
        _ok(_jsonRows(100, 1, pipeRow)),
        _ok(_jsonRows(7, 101, pipeRow)),
      ]);

      final pipes = await glab.pipelines('/repo', allHistory: true);

      expect(
        pipes,
        hasLength(107),
        reason: 'history past page 1 must accumulate',
      );
      expect(exec.calls, hasLength(2));
      expect(
        exec.calls[0],
        containsAllInOrder(['-f', 'per_page=100', '-f', 'page=1']),
      );
      expect(exec.calls[1], containsAllInOrder(['-f', 'page=2']));
      // A manual page walk, never `--paginate` (kept bounded per selection).
      expect(exec.calls.every((c) => !c.contains('--paginate')), isTrue);
    });
  });

  group('GlabService.graphqlArgs', () {
    test('binds each variable as its own -f field, never a variables blob', () {
      final args = GlabService.graphqlArgs(
        GlabService.projectDashboardQuery,
        variables: {'path': 'group/sub/repo'},
      );
      expect(args.take(3), ['glab', 'api', 'graphql']);
      expect(args.any((a) => a.startsWith('query=')), isTrue);
      // The variable must be bound by name so the query's `\$path` resolves.
      expect(args, contains('path=group/sub/repo'));
      // Regression guard: a single `variables={...}` blob leaves the declared
      // `\$path: ID!` unbound → "provided invalid value".
      expect(
        args.any((a) => a.startsWith('variables=')),
        isFalse,
        reason:
            'glab binds -f name=value to \$name; a variables={...} blob '
            'leaves declared query variables unbound',
      );
    });

    test('emits one -f flag per variable plus the query', () {
      final args = GlabService.graphqlArgs(
        'q',
        variables: {'a': '1', 'b': '2'},
      );
      expect(args.where((a) => a == '-f').length, 3);
      expect(args, containsAllInOrder(['-f', 'a=1']));
      expect(args, containsAllInOrder(['-f', 'b=2']));
    });
  });

  group('GlabService.graphqlErrorMessage', () {
    test('returns null when there are no errors', () {
      expect(
        GlabService.graphqlErrorMessage({
          'data': {'project': <String, dynamic>{}},
        }),
        isNull,
      );
      expect(
        GlabService.graphqlErrorMessage({
          'data': <String, dynamic>{},
          'errors': <Object?>[],
        }),
        isNull,
      );
    });

    test('joins the messages from the errors array', () {
      final msg = GlabService.graphqlErrorMessage({
        'errors': [
          {'message': r'variable $path of type ID! was provided invalid value'},
          {'message': 'second problem'},
        ],
      });
      expect(msg, contains('invalid value'));
      expect(msg, contains('second problem'));
    });

    test('falls back to a placeholder for a shapeless errors entry', () {
      final msg = GlabService.graphqlErrorMessage({
        'errors': [<String, dynamic>{}],
      });
      expect(msg, isNotNull);
    });
  });

  group('GlabService.projectDashboard', () {
    late _FakeExecutor exec;
    late GlabService glab;

    setUp(() {
      exec = _FakeExecutor();
      glab = GlabService(exec)..debugOriginHostOverride = 'gitlab.com';
    });

    // Real gitlab.com response shape (captured 2026-07). The load-bearing
    // detail: iid fields are **Strings** — the old `as num?` cast crashed the
    // whole dashboard parse for any project with an issue or milestone.
    const payload =
        'HTTP/2 200\ncontent-type: application/json\n\n'
        '{"data":{"project":{'
        '"issues":{"count":2577,"nodes":[{"iid":"606072","title":"T",'
        '"state":"opened","author":{"username":"bob"},'
        '"labels":{"nodes":[{"title":"backend"}]}}]},'
        '"labels":{"count":4217,"nodes":[{"title":"bug","color":"#34495E","description":null}]},'
        '"milestones":{"nodes":[{"iid":"2","title":"v0.5.0","state":"active","dueDate":"2026-07-22"}]},'
        '"releases":{"count":272,"nodes":[{"tagName":"v19.0.2","name":"v19.0.2",'
        '"releasedAt":"2026-07-01T17:57:10Z"}]}}}}';

    test('parses real String-iid payload (the crash regression)', () async {
      exec.results.addAll([_ok('git@gitlab.com:group/proj.git'), _ok(payload)]);
      final d = await glab.projectDashboard('/repo');
      expect(d.issues.single.id, 606072);
      expect(d.milestones.single.id, 2);
      expect(d.issuesTotal, 2577);
      expect(d.labelsTotal, 4217);
      // MilestoneConnection exposes no count — unknown, not zero.
      expect(d.milestonesTotal, isNull);
      expect(d.releasesTotal, 272);
      expect(d.warning, isNull);
    });

    test('a null project (nonexistent OR unauthorized — GitLab sends no error '
        'for either) throws instead of rendering an empty dashboard', () async {
      exec.results.addAll([
        _ok('git@gitlab.com:group/proj.git'),
        _ok('HTTP/2 200\n\n{"data":{"project":null}}'),
      ]);
      await expectLater(
        glab.projectDashboard('/repo'),
        throwsA(
          isA<GlabException>().having(
            (e) => e.message,
            'message',
            contains('group/proj'),
          ),
        ),
      );
    });

    test('an empty graphql body resets a stale warning', () async {
      // First call: partial data + errors → warning set.
      exec.next = _ok(
        'HTTP/2 200\n\n{"data":{"project":{}},"errors":[{"message":"partial"}]}',
      );
      await glab.graphql('/repo', 'q');
      expect(glab.lastGraphqlWarning, contains('partial'));

      // Second call: empty body — one of the early-return paths that used to
      // skip the assignment entirely and leak the first call's warning.
      exec.next = _ok('HTTP/2 200\n\n');
      await glab.graphql('/repo', 'q');
      expect(glab.lastGraphqlWarning, isNull);
    });
  });
}
