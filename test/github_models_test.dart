import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/github/models.dart';

void main() {
  group('PullRequest.fromJson', () {
    test('parses core fields and nested author', () {
      final pr = PullRequest.fromJson({
        'number': 42,
        'title': 'Add feature',
        'state': 'OPEN',
        'isDraft': false,
        'author': {'login': 'alice'},
        'headRefName': 'feature',
        'baseRefName': 'main',
        'url': 'https://github/pr/42',
      });
      expect(pr.number, 42);
      expect(pr.title, 'Add feature');
      expect(pr.state, 'open');
      expect(pr.authorLogin, 'alice');
      expect(pr.headRefName, 'feature');
      expect(pr.baseRefName, 'main');
      expect(pr.draft, isFalse);
      expect(pr.merged, isFalse);
    });

    test('derives merged from a MERGED state', () {
      final pr = PullRequest.fromJson({'number': 7, 'state': 'MERGED'});
      expect(pr.state, 'merged');
      expect(pr.merged, isTrue);
    });

    test('reads isDraft', () {
      final pr = PullRequest.fromJson({'number': 8, 'isDraft': true});
      expect(pr.draft, isTrue);
    });

    test('tolerates missing/malformed fields', () {
      final pr = PullRequest.fromJson({});
      expect(pr.number, 0);
      expect(pr.authorLogin, isNull);
      expect(pr.draft, isFalse);
      expect(pr.merged, isFalse);
    });
  });

  group('WorkflowRun.fromJson', () {
    test('parses fields and derives short sha', () {
      final r = WorkflowRun.fromJson({
        'databaseId': 1001,
        'status': 'completed',
        'conclusion': 'success',
        'headBranch': 'main',
        'headSha': '0123456789abcdef',
        'workflowName': 'CI',
        'event': 'push',
        'url': 'https://github/run/1001',
      });
      expect(r.id, 1001);
      expect(r.status, 'completed');
      expect(r.conclusion, 'success');
      expect(r.headBranch, 'main');
      expect(r.shortSha, '01234567');
      expect(r.runState, GhRunState.success);
      expect(r.isRerunnable, isFalse);
    });

    test('normalizes an empty conclusion to null (in-flight run)', () {
      final r = WorkflowRun.fromJson({
        'databaseId': 2,
        'status': 'in_progress',
        'conclusion': '',
      });
      expect(r.conclusion, isNull);
      expect(r.runState, GhRunState.running);
    });

    test('failed run is rerunnable', () {
      final r = WorkflowRun.fromJson({
        'databaseId': 3,
        'status': 'completed',
        'conclusion': 'failure',
      });
      expect(r.runState, GhRunState.failure);
      expect(r.isRerunnable, isTrue);
    });

    test('short sha is safe when sha is null or short', () {
      expect(WorkflowRun.fromJson({'databaseId': 1}).shortSha, '');
      expect(
        WorkflowRun.fromJson({'databaseId': 2, 'headSha': 'abc'}).shortSha,
        'abc',
      );
    });
  });

  group('GhRunState.from', () {
    test('maps completed conclusions', () {
      expect(GhRunState.from('completed', 'success'), GhRunState.success);
      expect(GhRunState.from('completed', 'failure'), GhRunState.failure);
      expect(GhRunState.from('completed', 'timed_out'), GhRunState.failure);
      expect(GhRunState.from('completed', 'cancelled'), GhRunState.canceled);
      expect(GhRunState.from('completed', 'skipped'), GhRunState.skipped);
      expect(
        GhRunState.from('completed', 'action_required'),
        GhRunState.actionRequired,
      );
      expect(GhRunState.from('completed', 'neutral'), GhRunState.neutral);
      expect(GhRunState.from('completed', 'weird'), GhRunState.unknown);
    });

    test('maps lifecycle states before completion', () {
      expect(GhRunState.from('in_progress', null), GhRunState.running);
      expect(GhRunState.from('queued', null), GhRunState.pending);
      expect(GhRunState.from('waiting', null), GhRunState.pending);
      expect(GhRunState.from('mystery', null), GhRunState.unknown);
    });
  });

  group('GhJob.fromJson', () {
    test('parses fields and state', () {
      final j = GhJob.fromJson({
        'id': 555,
        'name': 'unit-tests',
        'status': 'in_progress',
        'conclusion': null,
      });
      expect(j.id, 555);
      expect(j.name, 'unit-tests');
      expect(j.runState, GhRunState.running);
    });

    test('tolerates missing fields', () {
      final j = GhJob.fromJson({});
      expect(j.id, 0);
      expect(j.name, '');
    });
  });

  group('project models', () {
    test('GhLabel.fromJson prefixes bare hex color', () {
      final l = GhLabel.fromJson({'name': 'bug', 'color': 'd73a4a'});
      expect(l.name, 'bug');
      expect(l.color, '#d73a4a');
    });

    test('GhLabel.fromJson defaults color when missing', () {
      expect(GhLabel.fromJson({'name': 'x'}).color, '#888888');
    });

    test('GhMilestone.fromJson', () {
      final m = GhMilestone.fromJson({
        'number': 3,
        'title': 'v2',
        'state': 'OPEN',
        'due_on': '2026-08-01T00:00:00Z',
      });
      expect(m.number, 3);
      expect(m.title, 'v2');
      expect(m.state, 'open');
      expect(m.dueOn, '2026-08-01T00:00:00Z');
    });

    test('GhRelease.fromJson', () {
      final r = GhRelease.fromJson({
        'tag_name': 'v1.0',
        'name': 'First',
        'published_at': '2026-01-01T00:00:00Z',
      });
      expect(r.tagName, 'v1.0');
      expect(r.name, 'First');
    });

    test('GhIssue.fromJson parses label objects and author', () {
      final i = GhIssue.fromJson({
        'number': 9,
        'title': 'Bug',
        'state': 'OPEN',
        'author': {'login': 'bob'},
        'labels': [
          {'name': 'p1'},
          {'name': 'backend'},
        ],
      });
      expect(i.number, 9);
      expect(i.state, 'open');
      expect(i.authorLogin, 'bob');
      expect(i.labels, ['p1', 'backend']);
    });
  });
}
