import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';

void main() {
  group('MergeRequest.fromJson', () {
    test('parses core fields and nested author', () {
      final mr = MergeRequest.fromJson({
        'iid': 42,
        'title': 'Add feature',
        'state': 'opened',
        'author': {'username': 'alice'},
        'source_branch': 'feature',
        'target_branch': 'main',
        'web_url': 'https://gitlab/mr/42',
        'draft': false,
      });
      expect(mr.iid, 42);
      expect(mr.title, 'Add feature');
      expect(mr.authorUsername, 'alice');
      expect(mr.sourceBranch, 'feature');
      expect(mr.targetBranch, 'main');
      expect(mr.draft, isFalse);
    });

    test('falls back to legacy work_in_progress for draft', () {
      final mr = MergeRequest.fromJson({
        'iid': 7,
        'title': 'WIP thing',
        'work_in_progress': true,
      });
      expect(mr.draft, isTrue);
    });

    test('tolerates missing/malformed fields', () {
      final mr = MergeRequest.fromJson({});
      expect(mr.iid, 0);
      expect(mr.authorUsername, isNull);
      expect(mr.draft, isFalse);
    });
  });

  group('Pipeline.fromJson', () {
    test('parses fields and derives short sha', () {
      final p = Pipeline.fromJson({
        'id': 1001,
        'status': 'success',
        'ref': 'main',
        'sha': '0123456789abcdef',
        'web_url': 'https://gitlab/pipe/1001',
        'source': 'push',
      });
      expect(p.id, 1001);
      expect(p.status, 'success');
      expect(p.ref, 'main');
      expect(p.shortSha, '01234567');
      expect(p.source, 'push');
    });

    test('short sha is safe when sha is null or short', () {
      expect(Pipeline.fromJson({'id': 1}).shortSha, '');
      expect(Pipeline.fromJson({'id': 2, 'sha': 'abc'}).shortSha, 'abc');
    });
  });

  group('Job.fromJson', () {
    test('parses fields', () {
      final j = Job.fromJson({
        'id': 555,
        'name': 'unit-tests',
        'stage': 'test',
        'status': 'running',
      });
      expect(j.id, 555);
      expect(j.name, 'unit-tests');
      expect(j.stage, 'test');
      expect(j.status, 'running');
    });

    test('tolerates missing fields', () {
      final j = Job.fromJson({});
      expect(j.id, 0);
      expect(j.name, '');
    });
  });

  group('project models', () {
    test('Label.fromJson defaults color when missing', () {
      final l = Label.fromJson({'name': 'bug'});
      expect(l.name, 'bug');
      expect(l.color, '#888888');
    });

    test('Milestone.fromJson', () {
      final m = Milestone.fromJson({
        'iid': 3,
        'title': 'v2',
        'state': 'active',
        'due_date': '2026-08-01',
      });
      expect(m.iid, 3);
      expect(m.title, 'v2');
      expect(m.dueDate, '2026-08-01');
    });

    test('Release.fromJson', () {
      final r = Release.fromJson({
        'tag_name': 'v1.0',
        'name': 'First',
        'created_at': '2026-01-01',
      });
      expect(r.tagName, 'v1.0');
      expect(r.name, 'First');
    });

    test('Issue.fromJson parses labels list and author', () {
      final i = Issue.fromJson({
        'iid': 9,
        'title': 'Bug',
        'state': 'opened',
        'author': {'username': 'bob'},
        'labels': ['p1', 'backend'],
      });
      expect(i.iid, 9);
      expect(i.authorUsername, 'bob');
      expect(i.labels, ['p1', 'backend']);
    });
  });
}
