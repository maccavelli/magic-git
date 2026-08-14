// Tests for the shared forge project-dashboard models and their GraphQL
// factories. The GitLab node shapes here are copied from REAL gitlab.com
// GraphQL responses (2026-07) — most importantly, GitLab returns `iid` as a
// **String** ("606072"), which the old `as num?` cast crashed on for every
// project with at least one issue or milestone. The GitHub shapes come from a
// real `gh api graphql` run against cli/cli.
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/forge/forge_json.dart';

void main() {
  group('jsonIntOrNull', () {
    test('passes numbers through', () {
      expect(jsonIntOrNull(42), 42);
      expect(jsonIntOrNull(42.0), 42);
    });

    test('parses GitLab string iids', () {
      expect(jsonIntOrNull('606072'), 606072);
    });

    test('returns null on garbage — not a fabricated 0 that would collide', () {
      expect(jsonIntOrNull(null), isNull);
      expect(jsonIntOrNull('not-a-number'), isNull);
      expect(jsonIntOrNull(<int>[]), isNull);
    });
  });

  group('graphqlNodes / graphqlConnectionCount', () {
    test('maps nodes and reads GitHub totalCount', () {
      final conn = {
        'totalCount': 974,
        'nodes': [
          {'name': 'a'},
          {'name': 'b'},
        ],
      };
      expect(graphqlNodes(conn, (n) => n['name']), ['a', 'b']);
      expect(graphqlConnectionCount(conn), 974);
    });

    test('reads GitLab count', () {
      expect(graphqlConnectionCount({'count': 2577, 'nodes': <int>[]}), 2577);
    });

    test('missing connection or count is empty/unknown, never a crash', () {
      expect(graphqlNodes(null, (n) => n), isEmpty);
      expect(graphqlNodes({'nodes': 'bogus'}, (n) => n), isEmpty);
      expect(graphqlConnectionCount(null), isNull);
      expect(graphqlConnectionCount({'nodes': <int>[]}), isNull);
    });
  });

  group('GitLab GraphQL factories (real gitlab.com shapes)', () {
    test('ForgeIssue.fromGlabGql parses String iid', () {
      final issue = ForgeIssue.fromGlabGql({
        'iid': '606072',
        'title': 'Fix specs',
        'state': 'opened',
        'author': {'username': 'mcelicalderonG'},
        'labels': {
          'nodes': [
            {'title': 'backend'},
            {'title': 'devops::plan'},
          ],
        },
      });
      expect(issue.id, 606072);
      expect(issue.title, 'Fix specs');
      expect(issue.state, 'opened');
      expect(issue.author, 'mcelicalderonG');
      expect(issue.labels, ['backend', 'devops::plan']);
    });

    test('ForgeMilestone.fromGlabGql parses String iid and date-only due', () {
      final m = ForgeMilestone.fromGlabGql({
        'iid': '2',
        'title': 'v0.5.0',
        'state': 'closed',
        'dueDate': '2015-07-22',
      });
      expect(m.id, 2);
      expect(m.state, 'closed');
      expect(m.due, '2015-07-22');
    });

    test('ForgeMilestone.fromGlabRest keeps the REST web_url (global id ≠ iid, '
        'so the URL can only come from the payload)', () {
      final m = ForgeMilestone.fromGlabRest({
        'id': 90210, // global REST id — NOT the URL's iid
        'iid': 7,
        'title': 'Sprint 7',
        'state': 'active',
        'web_url': 'https://gitlab.example.com/grp/proj/-/milestones/7',
      });
      expect(m.id, 90210);
      expect(m.webUrl, 'https://gitlab.example.com/grp/proj/-/milestones/7');
    });

    test('ForgeMilestone.fromGhRest keeps html_url as webUrl', () {
      final m = ForgeMilestone.fromGhRest({
        'number': 3,
        'title': 'M3',
        'state': 'open',
        'html_url': 'https://github.com/o/r/milestone/3',
      });
      expect(m.webUrl, 'https://github.com/o/r/milestone/3');
    });

    test('ForgeLabel.fromGlabGql maps title to name', () {
      final l = ForgeLabel.fromGlabGql({
        'title': '#field-fyi',
        'color': '#34495E',
        'description': 'Earmarked.',
      });
      expect(l.name, '#field-fyi');
      expect(l.color, '#34495E');
      expect(l.description, 'Earmarked.');
    });

    test('ForgeRelease.fromGlabGql maps releasedAt', () {
      final r = ForgeRelease.fromGlabGql({
        'tagName': 'v19.0.2',
        'name': 'v19.0.2',
        'releasedAt': '2026-07-01T17:57:10Z',
        'description': 'Security fixes',
        'author': {'username': 'release-bot'},
      });
      expect(r.tagName, 'v19.0.2');
      expect(r.publishedAt, '2026-07-01T17:57:10Z');
      expect(r.publishedDate, '2026-07-01');
      expect(r.description, 'Security fixes');
      expect(r.author, 'release-bot');
    });
  });

  group('GitHub GraphQL factories (real api.github.com shapes)', () {
    test('ForgeIssue.fromGhGql parses Int number and uppercase state', () {
      final issue = ForgeIssue.fromGhGql({
        'number': 13881,
        'title': 'gh repo list --no-archived',
        'state': 'OPEN',
        'author': {'login': 'bburns-ds'},
        'labels': {
          'nodes': [
            {'name': 'needs-triage'},
          ],
        },
      });
      expect(issue.id, 13881);
      expect(issue.state, 'open');
      expect(issue.author, 'bburns-ds');
      expect(issue.labels, ['needs-triage']);
    });

    test('ForgeLabel.fromGhGql prefixes bare hex color', () {
      final l = ForgeLabel.fromGhGql({'name': 'bug', 'color': 'd73a4a'});
      expect(l.color, '#d73a4a');
    });

    test('ForgeLabel color defaults when missing', () {
      expect(ForgeLabel.fromGhGql({'name': 'x'}).color, '#888888');
      expect(ForgeLabel.fromGlabGql({'title': 'x'}).color, '#888888');
    });

    test('ForgeMilestone.fromGhGql normalizes ISO dueOn to date-only', () {
      final m = ForgeMilestone.fromGhGql({
        'number': 3,
        'title': 'v2',
        'state': 'OPEN',
        'dueOn': '2026-08-01T00:00:00Z',
      });
      expect(m.id, 3);
      expect(m.state, 'open');
      expect(m.due, '2026-08-01');
    });

    test('ForgeRelease.fromGhGql maps publishedAt', () {
      final r = ForgeRelease.fromGhGql({
        'tagName': 'v2.96.0',
        'name': 'GitHub CLI 2.96.0',
        'publishedAt': '2026-07-02T21:31:04Z',
        'description': 'CLI improvements',
        'author': {'login': 'cli'},
      });
      expect(r.name, 'GitHub CLI 2.96.0');
      expect(r.publishedDate, '2026-07-02');
      expect(r.description, 'CLI improvements');
      expect(r.author, 'cli');
    });
  });

  test('factories tolerate empty nodes', () {
    // A missing id is null (not a fabricated 0), so two id-less rows stay
    // distinguishable and can't collide on a shared key.
    expect(ForgeIssue.fromGhGql({}).id, isNull);
    expect(ForgeMilestone.fromGlabGql({}).id, isNull);
    expect(ForgeIssue.fromGlabGql({}).labels, isEmpty);
    expect(ForgeMilestone.fromGlabGql({}).due, isNull);
    expect(ForgeRelease.fromGhGql({}).publishedDate, isNull);
  });
}
