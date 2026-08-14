// Issue/milestone service methods (list, detail, create) and the CLI/REST
// model factories that parse their JSON. Argv-pinning mirrors the
// gh_glab_repo_ops/mutations harness; parsing pins the forge-neutral factories
// added for the Project tab.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    calls.add(gitArgs);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

// glab api rides `-i`, so its results carry an HTTP header block that
// [GlabService] strips before parsing.
const _glabHeaders = 'HTTP/2.0 200 OK\nContent-Type: application/json\n\n';

const _repo = '/repo';

void main() {
  late _FakeExecutor exec;
  late GhService gh;
  late GlabService glab;

  setUp(() {
    exec = _FakeExecutor();
    gh = GhService(exec);
    glab = GlabService(exec);
  });

  group('model factories', () {
    test('ForgeIssue.fromGlabCli: iid, string labels, author, description', () {
      final issue = ForgeIssue.fromGlabCli(const {
        'iid': 5,
        'title': 'Fix login',
        'state': 'opened',
        'author': {'username': 'mac'},
        'labels': ['bug', 'ui'],
        'description': 'Steps to repro\n',
      });
      expect(issue.id, 5);
      expect(issue.title, 'Fix login');
      expect(issue.state, 'opened');
      expect(issue.author, 'mac');
      expect(issue.labels, ['bug', 'ui']);
      expect(issue.body, 'Steps to repro');
    });

    test(
      'ForgeIssue.fromGlabCli: a list row without description has null body',
      () {
        final issue = ForgeIssue.fromGlabCli(const {'iid': 5, 'title': 'x'});
        expect(issue.body, isNull);
        expect(issue.labels, isEmpty);
      },
    );

    test('ForgeIssue.fromGhCli: number, {name} labels, login, body', () {
      final issue = ForgeIssue.fromGhCli(const {
        'number': 7,
        'title': 'Slow diff',
        'state': 'OPEN',
        'author': {'login': 'sam'},
        'labels': [
          {'name': 'perf'},
          {'name': 'ui'},
        ],
        'body': 'It is slow',
      });
      expect(issue.id, 7);
      expect(issue.state, 'open', reason: 'lowercased');
      expect(issue.author, 'sam');
      expect(issue.labels, ['perf', 'ui']);
      expect(issue.body, 'It is slow');
    });

    test('ForgeMilestone.fromGlabRest / fromGhRest parse due + description', () {
      // The global `id` is the key, not `iid`: include_ancestors mixes project
      // and group milestones whose per-parent iids can collide.
      final gl = ForgeMilestone.fromGlabRest(const {
        'id': 103,
        'iid': 3,
        'title': 'v1',
        'state': 'active',
        'due_date': '2026-08-01',
        'description': 'first milestone',
      });
      expect(gl.id, 103);
      expect(gl.due, '2026-08-01');
      expect(gl.description, 'first milestone');

      final gh = ForgeMilestone.fromGhRest(const {
        'number': 2,
        'title': 'v2',
        'state': 'open',
        'due_on': '2026-09-01T00:00:00Z',
        'description': 'second milestone',
      });
      expect(gh.id, 2);
      expect(gh.due, '2026-09-01', reason: 'ISO timestamp trimmed to date');
      expect(gh.description, 'second milestone');
    });
  });

  group('create issue argv', () {
    test('glab: full field set', () async {
      await glab.createIssue(
        _repo,
        title: 'T',
        description: 'D',
        labels: ['bug', 'ui'],
        assignees: ['mac'],
        milestone: 'v1',
      );
      expect(exec.calls.single, [
        'glab',
        'issue',
        'create',
        '--title',
        'T',
        '--description',
        'D',
        '--label',
        'bug,ui',
        '--assignee',
        'mac',
        '--milestone',
        'v1',
      ]);
    });

    test(
      'glab: an empty description is omitted (no interactive editor)',
      () async {
        await glab.createIssue(_repo, title: 'T');
        expect(exec.calls.single, ['glab', 'issue', 'create', '--title', 'T']);
      },
    );

    test(
      'gh: full field set, --body always present, per-item label/assignee',
      () async {
        await gh.createIssue(
          _repo,
          title: 'T',
          body: 'B',
          labels: ['bug', 'ui'],
          assignees: ['sam'],
          milestone: 'v2',
        );
        expect(exec.calls.single, [
          'gh',
          'issue',
          'create',
          '--title',
          'T',
          '--body',
          'B',
          '--label',
          'bug',
          '--label',
          'ui',
          '--assignee',
          'sam',
          '--milestone',
          'v2',
        ]);
      },
    );

    test(
      'gh: an empty body is still passed (never drops to an editor)',
      () async {
        await gh.createIssue(_repo, title: 'T');
        expect(exec.calls.single, [
          'gh',
          'issue',
          'create',
          '--title',
          'T',
          '--body',
          '',
        ]);
      },
    );
  });

  group('list issues', () {
    test('glab: collapsed fetches one page only', () async {
      exec.results.add(_ok('[{"iid":1,"title":"a"},{"iid":2,"title":"b"}]'));
      final issues = await glab.listIssues(_repo, perPage: 2);
      expect(issues.map((i) => i.id), [1, 2]);
      expect(exec.calls.single, [
        'glab',
        'issue',
        'list',
        '--output',
        'json',
        '--per-page',
        '2',
        '--page',
        '1',
      ]);
    });

    test('glab: allHistory walks pages until a short page ends it', () async {
      exec.results.addAll([
        _ok('[{"iid":1,"title":"a"},{"iid":2,"title":"b"}]'), // full page
        _ok('[{"iid":3,"title":"c"}]'), // short page → stop
      ]);
      final issues = await glab.listIssues(_repo, perPage: 2, allHistory: true);
      expect(issues.map((i) => i.id), [1, 2, 3]);
      expect(exec.calls.length, 2);
      expect(exec.calls[1].last, '2', reason: 'second call is --page 2');
    });

    test('gh: single --limit call; allHistory raises it', () async {
      exec.results.add(_ok('[{"number":9,"title":"z"}]'));
      await gh.listIssues(_repo);
      expect(exec.calls.single, [
        'gh',
        'issue',
        'list',
        '--state',
        'open',
        '--json',
        'number,title,state,author,labels',
        '--limit',
        '30',
      ]);

      exec.results.add(_ok('[]'));
      await gh.listIssues(_repo, allHistory: true);
      expect(exec.calls[1].last, '${GhService.fullHistoryLimit}');
    });
  });

  group('issue detail', () {
    test('glab: view <iid> --output json, parses the body', () async {
      exec.results.add(
        _ok('{"iid":5,"title":"Fix","description":"body text"}'),
      );
      final issue = await glab.issueDetail(_repo, 5);
      expect(issue.body, 'body text');
      expect(exec.calls.single, [
        'glab',
        'issue',
        'view',
        '5',
        '--output',
        'json',
      ]);
    });

    test('gh: view <number> --json includes body', () async {
      exec.results.add(_ok('{"number":7,"title":"Slow","body":"b"}'));
      final issue = await gh.issueDetail(_repo, 7);
      expect(issue.body, 'b');
      expect(exec.calls.single, [
        'gh',
        'issue',
        'view',
        '7',
        '--json',
        'number,title,state,author,labels,body',
      ]);
    });
  });

  group('list milestones', () {
    test(
      'glab: REST passthrough with state/per_page/page, -i headers',
      () async {
        exec.results.add(
          _ok('$_glabHeaders[{"id":3,"title":"v1","due_date":"2026-08-01"}]'),
        );
        final ms = await glab.listMilestones(_repo, perPage: 30);
        expect(ms.single.title, 'v1');
        expect(exec.calls.single, [
          'glab',
          'api',
          'projects/:id/milestones',
          '--method',
          'GET',
          '-f',
          'state=active',
          '-f',
          'include_ancestors=true',
          '-f',
          'per_page=30',
          '-f',
          'page=1',
          '-i',
        ]);
      },
    );

    test('gh: REST passthrough, collapsed fetches one page only', () async {
      exec.results.add(_ok('[{"number":2,"title":"v2"}]'));
      await gh.listMilestones(_repo);
      expect(exec.calls.single, [
        'gh',
        'api',
        'repos/{owner}/{repo}/milestones',
        '--method',
        'GET',
        '-f',
        'state=open',
        '-f',
        'per_page=30',
        '-f',
        'page=1',
      ]);
    });

    // A hand page-walk, NOT `gh api --paginate`: gh's --paginate emits one
    // JSON array per page back-to-back — invalid JSON as a single decode —
    // so past 100 milestones the "Show all" fetch would throw. glab's
    // --paginate merges pages; gh's does not.
    test('gh: allHistory walks pages until a short page ends it', () async {
      exec.results.addAll([
        _ok('[{"number":1,"title":"a"},{"number":2,"title":"b"}]'), // full page
        _ok('[{"number":3,"title":"c"}]'), // short page → stop
      ]);
      final ms = await gh.listMilestones(_repo, perPage: 2, allHistory: true);
      expect(ms.map((m) => m.id), [1, 2, 3]);
      expect(exec.calls.length, 2);
      expect(exec.calls[1].last, 'page=2', reason: 'second call is page 2');
      expect(
        exec.calls.every((c) => !c.contains('--paginate')),
        isTrue,
        reason: 'gh --paginate concatenates arrays into invalid JSON',
      );
    });
  });

  group('labels and releases page past the dashboard cap', () {
    // The GraphQL dashboard query caps labels at 100 and releases at 20, and
    // only REPORTS the overflow ("100 of 240"). These REST walks are what make
    // "Show all" a real affordance instead of a dead end.
    test('glab: labels walk pages until a short page', () async {
      exec.results.addAll([
        _ok('$_glabHeaders[{"name":"bug","color":"#f00"},{"name":"ux","color":"#0f0"}]'),
        _ok('$_glabHeaders[{"name":"docs","color":"#00f"}]'),
      ]);

      final labels = await glab.listLabels(_repo, perPage: 2);

      expect(labels.map((l) => l.name), ['bug', 'ux', 'docs']);
      expect(exec.calls.length, 2);
      expect(exec.calls[1], contains('page=2'));
      expect(
        exec.calls.every((c) => c.contains('-i')),
        isTrue,
        reason: "glab's exit codes are advisory — the -i HTTP status is the "
            'authority, and --paginate would force dropping it',
      );
    });

    test('glab: REST calls the field `name` where GraphQL calls it `title`',
        () async {
      exec.results.add(_ok('$_glabHeaders[{"name":"bug","color":"#ff0000"}]'));

      final labels = await glab.listLabels(_repo, perPage: 100);

      expect(labels.single.name, 'bug');
      expect(labels.single.color, '#ff0000');
    });

    test('glab: releases map snake_case fields', () async {
      exec.results.add(
        _ok(
          '$_glabHeaders[{"tag_name":"v1.0","name":"First",'
          '"released_at":"2026-01-01","author":{"username":"mac"}}]',
        ),
      );

      final releases = await glab.listReleases(_repo, perPage: 100);

      expect(releases.single.tagName, 'v1.0');
      expect(releases.single.name, 'First');
      expect(releases.single.publishedDate, '2026-01-01');
      expect(releases.single.author, 'mac');
    });

    test('gh: labels walk pages by hand, never --paginate', () async {
      exec.results.addAll([
        _ok('[{"name":"bug","color":"d73a4a"},{"name":"ux","color":"a2eeef"}]'),
        _ok('[{"name":"docs","color":"0075ca"}]'),
      ]);

      final labels = await gh.listLabels(_repo, perPage: 2);

      expect(labels.map((l) => l.name), ['bug', 'ux', 'docs']);
      // gh sends bare hex; the model normalizes it to #-prefixed.
      expect(labels.first.color, '#d73a4a');
      expect(
        exec.calls.every((c) => !c.contains('--paginate')),
        isTrue,
        reason: 'gh --paginate emits one array per page — invalid JSON to a '
            'single decode',
      );
    });

    test('gh: a release with no name falls back to its tag', () async {
      exec.results.add(
        _ok('[{"tag_name":"v2.0","name":"","published_at":"2026-02-02",'
            '"author":{"login":"mac"}}]'),
      );

      final releases = await gh.listReleases(_repo, perPage: 100);

      expect(releases.single.name, 'v2.0');
      expect(releases.single.author, 'mac');
    });
  });
}
