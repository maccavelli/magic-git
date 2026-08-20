// Curated activity labels for forge mutations (plan 0005 Phase 2 claimed
// these shipped; every forge command actually reported as "Update forge").
//
// Two properties carry the weight: a READ must never produce a label at all
// (an activity entry implies something changed), and an unrecognized command
// must fall back rather than guess.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge_operation_labels.dart';

void main() {
  group('CLI mutations', () {
    test('GitHub pull-request verbs', () {
      expect(
        forgeOperationLabel(['gh', 'pr', 'merge', '42']),
        'Merge pull request',
      );
      expect(
        forgeOperationLabel(['gh', 'pr', 'close', '42']),
        'Close pull request',
      );
      expect(
        forgeOperationLabel(['gh', 'pr', 'checkout', '42']),
        'Check out pull request',
      );
      expect(
        forgeOperationLabel(['gh', 'pr', 'ready', '42']),
        'Change pull request draft state',
      );
    });

    test('GitLab says "merge request", GitHub says "pull request"', () {
      expect(
        forgeOperationLabel(['glab', 'mr', 'merge', '7']),
        'Merge merge request',
      );
      expect(
        forgeOperationLabel(['gh', 'pr', 'merge', '7']),
        'Merge pull request',
      );
    });

    test('issue verbs', () {
      expect(forgeOperationLabel(['gh', 'issue', 'close', '3']), 'Close issue');
      expect(
        forgeOperationLabel(['glab', 'issue', 'comment', '3']),
        'Comment on issue',
      );
      expect(
        forgeOperationLabel(['gh', 'issue', 'develop', '3']),
        'Start work on issue',
      );
    });

    test('sign-in and repository creation name their forge', () {
      expect(
        forgeOperationLabel(['gh', 'auth', 'login', '--with-token']),
        'Sign in to GitHub',
      );
      expect(
        forgeOperationLabel(['glab', 'auth', 'login', '--stdin']),
        'Sign in to GitLab',
      );
      expect(
        forgeOperationLabel(['glab', 'repo', 'create', 'x']),
        'Create GitLab project',
      );
    });

    test('CI verbs', () {
      expect(
        forgeOperationLabel(['gh', 'run', 'rerun', '100', '--failed']),
        'Re-run failed jobs',
      );
      expect(
        forgeOperationLabel(['glab', 'ci', 'retry', '100']),
        'Retry pipeline',
      );
    });
  });

  group('REST-routed mutations', () {
    test('a GET produces no label — an activity entry implies a change', () {
      expect(
        forgeOperationLabel([
          'glab',
          'api',
          'projects/:id/labels',
          '--method',
          'GET',
        ]),
        isNull,
      );
      // No --method at all defaults to GET.
      expect(
        forgeOperationLabel(['gh', 'api', 'repos/{owner}/{repo}']),
        isNull,
      );
    });

    test('merge and auto-merge share an endpoint but not a label', () {
      const base = [
        'glab',
        'api',
        'projects/:id/merge_requests/7/merge',
        '--method',
        'PUT',
      ];
      expect(forgeOperationLabel(base), 'Merge merge request');
      // The only thing separating the two on the wire is this field.
      expect(
        forgeOperationLabel([
          ...base,
          '-f',
          'merge_when_pipeline_succeeds=true',
        ]),
        'Enable auto-merge',
      );
    });

    test('the other GitLab REST mutations', () {
      expect(
        forgeOperationLabel([
          'glab',
          'api',
          'projects/:id/merge_requests/7/cancel_merge_when_pipeline_succeeds',
          '--method',
          'POST',
        ]),
        'Cancel auto-merge',
      );
      expect(
        forgeOperationLabel([
          'glab',
          'api',
          'projects/:id/merge_requests/7/rebase',
          '--method',
          'POST',
        ]),
        'Rebase merge request',
      );
      expect(
        forgeOperationLabel([
          'glab',
          'api',
          'projects/:id/merge_requests/7/approve',
          '--method',
          'POST',
        ]),
        'Approve merge request',
      );
    });

    test('GitHub update-branch', () {
      expect(
        forgeOperationLabel([
          'gh',
          'api',
          'repos/{owner}/{repo}/pulls/42/update-branch',
          '--method',
          'PUT',
        ]),
        'Update pull request branch',
      );
    });
  });

  group('fallback', () {
    test(
      'an unrecognized command yields null so the caller can be generic',
      () {
        expect(forgeOperationLabel(['gh', 'something', 'weird']), isNull);
        expect(forgeOperationLabel(['git', 'push']), isNull);
        expect(forgeOperationLabel(['gh']), isNull);
        expect(forgeOperationLabel([]), isNull);
      },
    );
  });
}
