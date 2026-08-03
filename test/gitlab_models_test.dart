import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';

Map<String, dynamic> _fixture(String name) {
  final f = File('test/fixtures/forge/$name');
  final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  map.remove('_fixture');
  map.remove('_cli');
  return map;
}

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
      expect(mr.labels, isEmpty);
      expect(mr.hasConflicts, isFalse);
    });

    test('parses list enrichment from fixture', () {
      final mr = MergeRequest.fromJson(_fixture('glab_mr_list_item.json'));
      expect(mr.iid, 17);
      expect(mr.labels, ['bug', 'priority::2']);
      expect(mr.assigneeUsernames, ['bob']);
      expect(mr.detailedMergeStatus, 'not_approved');
      expect(mr.sha, startsWith('abcdef01'));
      expect(mr.hasConflicts, isFalse);
    });

    test('parses detail mergeable fixture', () {
      final mr = MergeRequest.fromJson(_fixture('glab_mr_view_mergeable.json'));
      expect(mr.detailedMergeStatus, 'mergeable');
      expect(mr.sha, isNotNull);
      expect(mr.shortSha.length, 8);
      expect(mr.description, contains('timeout'));
      expect(mr.userCanMerge, isTrue);
      expect(mr.shouldRemoveSourceBranch, isTrue);
    });

    test('parses conflict detail fixture', () {
      final mr = MergeRequest.fromJson(_fixture('glab_mr_view_conflict.json'));
      expect(mr.detailedMergeStatus, 'conflict');
      expect(mr.hasConflicts, isTrue);
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

  group('CiStatus.needsAttention', () {
    test('failed and every non-terminal state are attention-worthy', () {
      // The states the old inline {failed, running, pending} check MISSED.
      for (final s in [
        CiStatus.failed,
        CiStatus.running,
        CiStatus.pending,
        CiStatus.created,
        CiStatus.waitingForResource,
        CiStatus.preparing,
        CiStatus.scheduled,
        CiStatus.manual,
      ]) {
        expect(s.needsAttention, isTrue, reason: '$s should need attention');
      }
      expect(
        CiStatus.fromWire('waiting_for_resource'),
        CiStatus.waitingForResource,
      );
    });

    test('terminal and unrecognized states stay out', () {
      for (final s in [
        CiStatus.success,
        CiStatus.canceled,
        CiStatus.skipped,
        CiStatus.unknown,
      ]) {
        expect(s.needsAttention, isFalse, reason: '$s should stay out');
      }
    });
  });
}
