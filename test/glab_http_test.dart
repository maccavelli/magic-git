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
      expect(GlabService.projectDashboardQuery, contains('issues(state: opened'));
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
      glab = GlabService(exec);
    });

    test(
      'paginated calls drop -i (which is incompatible with --paginate); '
      'non-paginated calls keep it',
      () async {
        // `--paginate` + `-i` interleaves a header block per page, so the
        // leading-header strip + first-status-line read only ever see page 1.
        await glab.issues('/repo');
        expect(exec.calls.single, contains('--paginate'));
        expect(
          exec.calls.single,
          isNot(contains('-i')),
          reason: 'a paginated call must not combine -i with --paginate',
        );

        exec.calls.clear();
        await glab.releases('/repo');
        expect(exec.calls.single, contains('--paginate'));
        expect(exec.calls.single, isNot(contains('-i')));

        // A non-paginated call still uses -i to catch a misleading exit code.
        exec.calls.clear();
        await glab.pipelines('/repo');
        expect(exec.calls.single, isNot(contains('--paginate')));
        expect(exec.calls.single, contains('-i'));
      },
    );

    test('jobs walks pages until a short page and accumulates all of them', () async {
      String jobRow(int id) =>
          '{"id":$id,"name":"j$id","stage":"build","status":"success"}';
      // Page 1 is full (100) → keep going; page 2 is short (5) → stop.
      exec.results.addAll([
        _ok(_jsonRows(100, 1, jobRow)),
        _ok(_jsonRows(5, 101, jobRow)),
      ]);

      final jobs = await glab.jobs('/repo', 7);

      expect(jobs, hasLength(105), reason: 'jobs past #100 must not be dropped');
      expect(exec.calls, hasLength(2));
      expect(exec.calls[0], containsAllInOrder(['-f', 'page=1']));
      expect(exec.calls[1], containsAllInOrder(['-f', 'page=2']));
      // A manual page walk, never `--paginate` (kept bounded per selection).
      expect(exec.calls.every((c) => !c.contains('--paginate')), isTrue);
    });

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
        reason: 'glab binds -f name=value to \$name; a variables={...} blob '
            'leaves declared query variables unbound',
      );
    });

    test('emits one -f flag per variable plus the query', () {
      final args = GlabService.graphqlArgs('q', variables: {'a': '1', 'b': '2'});
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
}
