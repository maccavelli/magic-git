import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';

PullRequest _pr({
  bool draft = false,
  GhMergeable mergeable = GhMergeable.unknown,
  String? mergeStateStatus,
  String? reviewDecision,
  String? headOid,
  bool autoMergeEnabled = false,
}) => PullRequest(
  number: 1,
  title: 't',
  state: 'open',
  merged: false,
  draft: draft,
  headRefName: 'feat',
  baseRefName: 'main',
  url: '',
  mergeable: mergeable,
  mergeStateStatus: mergeStateStatus,
  reviewDecision: reviewDecision,
  headOid: headOid,
  autoMergeEnabled: autoMergeEnabled,
);

MergeRequest _mr({
  bool draft = false,
  bool hasConflicts = false,
  String? detailedMergeStatus,
  String? sha,
  bool mergeWhenPipelineSucceeds = false,
}) => MergeRequest(
  iid: 1,
  title: 't',
  state: 'opened',
  sourceBranch: 'feat',
  targetBranch: 'main',
  webUrl: '',
  draft: draft,
  hasConflicts: hasConflicts,
  detailedMergeStatus: detailedMergeStatus,
  sha: sha,
  mergeWhenPipelineSucceeds: mergeWhenPipelineSucceeds,
);

void main() {
  group('mergePlanForGitHub', () {
    test('list-tier row without detail is mergeable if not draft', () {
      final plan = mergePlanForGitHub(pr: _pr());
      expect(plan.canMergeNow, isTrue);
      expect(plan.allowedMethods, hasLength(3));
      expect(plan.defaultMethod, MergeMethod.mergeCommit);
      expect(plan.pinHeadSha, isFalse);
    });

    test('draft blocks merge', () {
      final plan = mergePlanForGitHub(pr: _pr(draft: true));
      expect(plan.canMergeNow, isFalse);
      expect(plan.blockedReasons.any((r) => r.code == 'draft'), isTrue);
    });

    test('ready detail enables merge and pins SHA', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.mergeable,
          mergeStateStatus: 'CLEAN',
          reviewDecision: 'APPROVED',
          headOid: 'abc123456789',
        ),
      );
      expect(plan.canMergeNow, isTrue);
      expect(plan.pinHeadSha, isTrue);
      expect(plan.headSha, 'abc123456789');
    });

    test('conflicts block merge', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.conflicting,
          mergeStateStatus: 'DIRTY',
          headOid: 'abc',
        ),
      );
      expect(plan.canMergeNow, isFalse);
      expect(plan.blockedReasons.any((r) => r.code == 'conflicts'), isTrue);
    });

    test('review required blocks merge', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.mergeable,
          mergeStateStatus: 'CLEAN',
          reviewDecision: 'REVIEW_REQUIRED',
          headOid: 'abc',
        ),
      );
      expect(plan.canMergeNow, isFalse);
      expect(plan.blockedReasons.any((r) => r.code == 'review'), isTrue);
    });

    test('changes requested blocks merge', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.mergeable,
          reviewDecision: 'CHANGES_REQUESTED',
          headOid: 'abc',
        ),
      );
      expect(plan.canMergeNow, isFalse);
    });

    test('unknown mergeable with detail blocks and offers no false ready', () {
      final plan = mergePlanForGitHub(
        pr: _pr(mergeable: GhMergeable.unknown, headOid: 'abc'),
      );
      expect(plan.canMergeNow, isFalse);
      expect(
        plan.blockedReasons.any((r) => r.code == 'mergeability_unknown'),
        isTrue,
      );
    });

    test('behind sets needsBranchUpdate', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.mergeable,
          mergeStateStatus: 'BEHIND',
          headOid: 'abc',
        ),
      );
      expect(plan.canMergeNow, isFalse);
      expect(plan.needsBranchUpdate, isTrue);
    });

    test('policy filters allowed methods and defaults to squash', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.mergeable,
          mergeStateStatus: 'CLEAN',
          headOid: 'abc',
        ),
        policy: const GhRepoMergePolicy(
          allowMergeCommit: false,
          allowSquashMerge: true,
          allowRebaseMerge: false,
          deleteBranchOnMerge: true,
        ),
      );
      expect(plan.allowedMethods, [MergeMethod.squash]);
      expect(plan.defaultMethod, MergeMethod.squash);
      expect(plan.defaultDeleteSource, isTrue);
    });

    test('auto-merge already enabled disables immediate merge', () {
      final plan = mergePlanForGitHub(
        pr: _pr(
          mergeable: GhMergeable.mergeable,
          mergeStateStatus: 'CLEAN',
          headOid: 'abc',
          autoMergeEnabled: true,
        ),
      );
      expect(plan.canMergeNow, isFalse);
      expect(plan.autoMergeAlreadyEnabled, isTrue);
    });
  });

  group('mergePlanForGitLab', () {
    test('list-tier without status is mergeable if not draft', () {
      final plan = mergePlanForGitLab(mr: _mr());
      expect(plan.canMergeNow, isTrue);
    });

    test('draft blocks', () {
      final plan = mergePlanForGitLab(mr: _mr(draft: true));
      expect(plan.canMergeNow, isFalse);
    });

    test('mergeable with sha pins', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'mergeable', sha: 'deadbeef'),
      );
      expect(plan.canMergeNow, isTrue);
      expect(plan.pinHeadSha, isTrue);
    });

    test('conflict blocks', () {
      final plan = mergePlanForGitLab(mr: _mr(hasConflicts: true, sha: 'x'));
      expect(plan.canMergeNow, isFalse);
      expect(plan.blockedReasons.any((r) => r.code == 'conflicts'), isTrue);
    });

    test('not_approved blocks', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'not_approved', sha: 'x'),
      );
      expect(plan.canMergeNow, isFalse);
    });

    test('ci_still_running allows auto-merge only', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'ci_still_running', sha: 'x'),
      );
      expect(plan.canMergeNow, isFalse);
      expect(plan.canEnableAutoMerge, isTrue);
    });

    test('need_rebase sets needsBranchUpdate', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'need_rebase', sha: 'x'),
      );
      expect(plan.needsBranchUpdate, isTrue);
      expect(plan.canMergeNow, isFalse);
    });

    test('squash never hides squash method', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'mergeable', sha: 'x'),
        policy: const GlRepoMergePolicy(squashOption: 'never'),
      );
      expect(plan.allowedMethods, [MergeMethod.mergeCommit]);
    });

    test('squash always hides the plain merge method, not just re-defaults', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'mergeable', sha: 'x'),
        policy: const GlRepoMergePolicy(squashOption: 'always'),
      );
      // GitLab ignores squash=false on such a project, and the options sheet
      // clamps to allowedMethods — so leaving mergeCommit here meant the UI
      // offered a "Merge" that silently performed a squash.
      expect(plan.allowedMethods, [MergeMethod.squash]);
      expect(plan.defaultMethod, MergeMethod.squash);
    });

    test('default_on pre-selects squash but keeps merge available', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'mergeable', sha: 'x'),
        policy: const GlRepoMergePolicy(squashOption: 'default_on'),
      );
      expect(plan.allowedMethods, [MergeMethod.mergeCommit, MergeMethod.squash]);
      expect(plan.defaultMethod, MergeMethod.squash);
    });

    test('default_off offers both and defaults to a merge commit', () {
      final plan = mergePlanForGitLab(
        mr: _mr(detailedMergeStatus: 'mergeable', sha: 'x'),
        policy: const GlRepoMergePolicy(squashOption: 'default_off'),
      );
      expect(plan.allowedMethods, [MergeMethod.mergeCommit, MergeMethod.squash]);
      expect(plan.defaultMethod, MergeMethod.mergeCommit);
    });
  });

  group('policy parsers', () {
    test('GhRepoMergePolicy.fromJson', () {
      final p = GhRepoMergePolicy.fromJson({
        'default_branch': 'trunk',
        'allow_merge_commit': false,
        'allow_squash_merge': true,
        'allow_rebase_merge': true,
        'allow_auto_merge': true,
        'delete_branch_on_merge': true,
      });
      expect(p.allowMergeCommit, isFalse);
      expect(p.defaultBranch, 'trunk');
      expect(p.allowSquashMerge, isTrue);
      expect(p.allowAutoMerge, isTrue);
      expect(p.deleteBranchOnMerge, isTrue);
    });

    test('GlRepoMergePolicy.fromJson', () {
      final p = GlRepoMergePolicy.fromJson({
        'default_branch': 'develop',
        'merge_method': 'ff',
        'squash_option': 'always',
        'remove_source_branch_after_merge': true,
      });
      expect(p.mergeMethod, 'ff');
      expect(p.defaultBranch, 'develop');
      expect(p.squashAlways, isTrue);
      expect(p.removeSourceBranchAfterMerge, isTrue);
    });

    test('GlRepoMergePolicy reads GitLab\'s real squash_option enum', () {
      // The enum is never | always | default_on | default_off. The code used
      // to test for 'encourage'/'encouraged' and default to 'allowed' —
      // neither of which GitLab sends, so squashEncouraged never once fired.
      expect(
        const GlRepoMergePolicy(squashOption: 'default_on').squashEncouraged,
        isTrue,
      );
      expect(
        const GlRepoMergePolicy(squashOption: 'default_off').squashEncouraged,
        isFalse,
      );
      expect(
        const GlRepoMergePolicy(squashOption: 'default_off').squashNever,
        isFalse,
      );
      expect(
        const GlRepoMergePolicy(squashOption: 'default_off').squashAlways,
        isFalse,
      );
      // An unset policy must offer both methods, not silently forbid one.
      expect(const GlRepoMergePolicy().squashNever, isFalse);
      expect(const GlRepoMergePolicy().squashAlways, isFalse);
    });
  });
}
