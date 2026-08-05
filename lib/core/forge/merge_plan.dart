/// Pure merge-decision logic for forge change requests (GitHub PRs / GitLab MRs).
///
/// UI and services never invent enablement rules ad hoc: they build a
/// [MergePlan] from detail (+ optional repo policy) and drive buttons from it.
library;

import '../github/models.dart';
import '../gitlab/models.dart';

/// User-selectable merge strategies. GitHub maps all three to `gh pr merge`
/// flags; GitLab's project merge method is separate — per-MR the user mainly
/// chooses squash vs not (rebase is not a per-MR menu item).
enum MergeMethod { mergeCommit, squash, rebase }

/// Stable reason code + human message for why merge is blocked or deferred.
class MergeBlockedReason {
  final String code;
  final String message;

  const MergeBlockedReason(this.code, this.message);

  @override
  bool operator ==(Object other) =>
      other is MergeBlockedReason &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'MergeBlockedReason($code: $message)';
}

/// Computed, forge-agnostic plan for the merge UI.
class MergePlan {
  final bool canMergeNow;
  final bool canEnableAutoMerge;
  final List<MergeBlockedReason> blockedReasons;
  final List<MergeMethod> allowedMethods;
  final MergeMethod defaultMethod;
  final bool defaultDeleteSource;
  final String? headSha;

  /// When true, merge mutations must pin [headSha] (`--match-head-commit` / `sha=`).
  final bool pinHeadSha;
  final bool supportsAdminBypass;
  final bool autoMergeAlreadyEnabled;

  /// Behind base / need_rebase — UI may offer update-branch / rebase instead.
  final bool needsBranchUpdate;

  const MergePlan({
    required this.canMergeNow,
    required this.canEnableAutoMerge,
    required this.blockedReasons,
    required this.allowedMethods,
    required this.defaultMethod,
    required this.defaultDeleteSource,
    this.headSha,
    required this.pinHeadSha,
    this.supportsAdminBypass = false,
    this.autoMergeAlreadyEnabled = false,
    this.needsBranchUpdate = false,
  });

  /// Tooltip / first-line summary of why merge is disabled.
  String get blockedSummary {
    if (blockedReasons.isEmpty) return '';
    return blockedReasons.map((r) => r.message).join(' · ');
  }
}

/// GitHub repo settings that constrain merge methods (from `gh api` repo object).
class GhRepoMergePolicy {
  final String? defaultBranch;
  final bool allowMergeCommit;
  final bool allowSquashMerge;
  final bool allowRebaseMerge;
  final bool allowAutoMerge;
  final bool deleteBranchOnMerge;

  const GhRepoMergePolicy({
    this.defaultBranch,
    this.allowMergeCommit = true,
    this.allowSquashMerge = true,
    this.allowRebaseMerge = true,
    this.allowAutoMerge = false,
    this.deleteBranchOnMerge = false,
  });

  factory GhRepoMergePolicy.fromJson(Map<String, dynamic> json) =>
      GhRepoMergePolicy(
        defaultBranch: json['default_branch'] as String?,
        allowMergeCommit: (json['allow_merge_commit'] as bool?) ?? true,
        allowSquashMerge: (json['allow_squash_merge'] as bool?) ?? true,
        allowRebaseMerge: (json['allow_rebase_merge'] as bool?) ?? true,
        allowAutoMerge: (json['allow_auto_merge'] as bool?) ?? false,
        deleteBranchOnMerge: (json['delete_branch_on_merge'] as bool?) ?? false,
      );
}

/// GitLab project merge settings (from `glab api projects/:id`).
class GlRepoMergePolicy {
  final String? defaultBranch;

  /// `merge` | `rebase_merge` | `ff`
  final String mergeMethod;

  /// `never` | `allowed` | `encouraged` | `always`
  final String squashOption;
  final bool removeSourceBranchAfterMerge;
  final bool autoMergeEnabled;

  const GlRepoMergePolicy({
    this.defaultBranch,
    this.mergeMethod = 'merge',
    this.squashOption = 'allowed',
    this.removeSourceBranchAfterMerge = false,
    this.autoMergeEnabled = true,
  });

  factory GlRepoMergePolicy.fromJson(Map<String, dynamic> json) =>
      GlRepoMergePolicy(
        defaultBranch: json['default_branch'] as String?,
        mergeMethod: json['merge_method'] as String? ?? 'merge',
        squashOption: json['squash_option'] as String? ?? 'allowed',
        removeSourceBranchAfterMerge:
            (json['remove_source_branch_after_merge'] as bool?) ?? false,
        autoMergeEnabled: (json['auto_merge_enabled'] as bool?) ?? true,
      );

  bool get squashNever => squashOption == 'never';
  bool get squashAlways => squashOption == 'always';
  bool get squashEncouraged =>
      squashOption == 'encourage' || squashOption == 'encouraged';
}

/// Build a [MergePlan] for a GitHub pull request.
///
/// Hard-blocks on known bad signals (draft, conflicts, changes requested,
/// review required, dirty/blocked/behind). When signals are absent (list-only
/// row without detail), only draft is enforced — other gates rely on the forge
/// at merge time (soft-open).
MergePlan mergePlanForGitHub({
  required PullRequest pr,
  GhRepoMergePolicy? policy,
}) {
  final reasons = <MergeBlockedReason>[];
  var needsUpdate = false;
  var canAuto = false;

  if (pr.draft) {
    reasons.add(
      const MergeBlockedReason(
        'draft',
        "Draft pull requests can't be merged — mark it ready first.",
      ),
    );
  }

  switch (pr.mergeable) {
    case GhMergeable.conflicting:
      reasons.add(
        const MergeBlockedReason(
          'conflicts',
          'This branch has conflicts that must be resolved.',
        ),
      );
    case GhMergeable.unknown:
      // Only treat as "still computing" when detail was loaded (we have a
      // mergeStateStatus or headOid) — pure list rows keep mergeable=unknown
      // with no detail and must not hard-block.
      if (pr.headOid != null || pr.mergeStateStatus != null) {
        reasons.add(
          const MergeBlockedReason(
            'mergeability_unknown',
            'Mergeability is still computing — try again in a moment.',
          ),
        );
      }
    case GhMergeable.mergeable:
      break;
  }

  final status = (pr.mergeStateStatus ?? '').toUpperCase();
  switch (status) {
    case 'DIRTY':
      if (!reasons.any((r) => r.code == 'conflicts')) {
        reasons.add(
          const MergeBlockedReason(
            'conflicts',
            'This branch has conflicts that must be resolved.',
          ),
        );
      }
    case 'BLOCKED':
      reasons.add(
        const MergeBlockedReason(
          'blocked',
          'Merge is blocked by branch protection or required checks.',
        ),
      );
      // Pending checks often mean auto-merge is the right path.
      canAuto = !pr.draft && pr.mergeable != GhMergeable.conflicting;
    case 'BEHIND':
      reasons.add(
        const MergeBlockedReason(
          'behind',
          'Head branch is behind the base — update the branch first.',
        ),
      );
      needsUpdate = true;
    case 'UNSTABLE':
      // Non-required checks failing — GitHub still allows merge; do not block.
      break;
    case 'HAS_HOOKS':
    case 'CLEAN':
    case 'UNKNOWN':
    case '':
      break;
    default:
      break;
  }

  final review = (pr.reviewDecision ?? '').toUpperCase();
  switch (review) {
    case 'CHANGES_REQUESTED':
      reasons.add(
        const MergeBlockedReason(
          'review',
          'Changes have been requested on this pull request.',
        ),
      );
    case 'REVIEW_REQUIRED':
      reasons.add(
        const MergeBlockedReason(
          'review',
          'Required reviews are still outstanding.',
        ),
      );
    case 'APPROVED':
    case '':
      break;
    default:
      break;
  }

  final methods = <MergeMethod>[];
  if (policy == null) {
    methods.addAll([
      MergeMethod.mergeCommit,
      MergeMethod.squash,
      MergeMethod.rebase,
    ]);
  } else {
    if (policy.allowMergeCommit) methods.add(MergeMethod.mergeCommit);
    if (policy.allowSquashMerge) methods.add(MergeMethod.squash);
    if (policy.allowRebaseMerge) methods.add(MergeMethod.rebase);
  }
  if (methods.isEmpty) {
    methods.add(MergeMethod.mergeCommit);
  }

  // Default: with no policy, keep historical UI (merge commit primary +
  // squash/rebase in the pulldown). When policy is known, prefer squash if
  // allowed (common team default); else merge commit; else first allowed.
  final MergeMethod defaultMethod;
  if (policy == null) {
    defaultMethod = methods.contains(MergeMethod.mergeCommit)
        ? MergeMethod.mergeCommit
        : methods.first;
  } else {
    defaultMethod = methods.contains(MergeMethod.squash)
        ? MergeMethod.squash
        : methods.contains(MergeMethod.mergeCommit)
        ? MergeMethod.mergeCommit
        : methods.first;
  }

  final autoAlready = pr.autoMergeEnabled;
  final headSha = pr.headOid;
  final pin = headSha != null && headSha.isNotEmpty;

  // Auto-merge only when policy allows (or unknown) and not already enabled.
  if (autoAlready) {
    canAuto = false;
  } else if (policy != null && !policy.allowAutoMerge) {
    canAuto = false;
  } else if (pr.draft || pr.mergeable == GhMergeable.conflicting) {
    canAuto = false;
  } else if (reasons.any(
    (r) => r.code == 'review' || r.code == 'conflicts' || r.code == 'behind',
  )) {
    // Review / conflicts / behind cannot be fixed by waiting for checks alone.
    if (reasons.any((r) => r.code == 'blocked')) {
      // keep canAuto if set above for BLOCKED
    } else {
      canAuto = false;
    }
  }

  // If only blocked on pending checks / unknown mergeability, allow auto-merge.
  final hardBlockCodes = {'draft', 'conflicts', 'review', 'behind'};
  final onlySoftBlocks =
      reasons.isNotEmpty &&
      reasons.every((r) => !hardBlockCodes.contains(r.code));
  if (onlySoftBlocks &&
      !pr.draft &&
      !autoAlready &&
      (policy == null || policy.allowAutoMerge)) {
    canAuto = true;
  }

  final canNow = reasons.isEmpty && !autoAlready;

  return MergePlan(
    canMergeNow: canNow,
    canEnableAutoMerge: canAuto && !canNow,
    blockedReasons: reasons,
    allowedMethods: methods,
    defaultMethod: defaultMethod,
    defaultDeleteSource: policy?.deleteBranchOnMerge ?? false,
    headSha: headSha,
    pinHeadSha: pin,
    supportsAdminBypass: true,
    autoMergeAlreadyEnabled: autoAlready,
    needsBranchUpdate: needsUpdate,
  );
}

/// Build a [MergePlan] for a GitLab merge request.
MergePlan mergePlanForGitLab({
  required MergeRequest mr,
  GlRepoMergePolicy? policy,
}) {
  final reasons = <MergeBlockedReason>[];
  var needsUpdate = false;
  var canAuto = false;

  if (mr.draft) {
    reasons.add(
      const MergeBlockedReason(
        'draft',
        "Draft merge requests can't be merged — mark it ready first.",
      ),
    );
  }

  if (mr.hasConflicts) {
    reasons.add(
      const MergeBlockedReason(
        'conflicts',
        'This branch has conflicts that must be resolved.',
      ),
    );
  }

  final status = (mr.detailedMergeStatus ?? mr.mergeStatus ?? '').toLowerCase();
  switch (status) {
    case 'mergeable':
    case 'can_be_merged':
      break;
    case 'conflict':
    case 'cannot_be_merged':
      if (!mr.hasConflicts) {
        reasons.add(
          const MergeBlockedReason(
            'conflicts',
            'This branch has conflicts that must be resolved.',
          ),
        );
      }
    case 'discussions_not_resolved':
      reasons.add(
        const MergeBlockedReason(
          'discussions',
          'Unresolved discussions must be resolved before merge.',
        ),
      );
    case 'not_approved':
      reasons.add(
        const MergeBlockedReason(
          'review',
          'Required approvals are still outstanding.',
        ),
      );
    case 'ci_must_pass':
      reasons.add(
        const MergeBlockedReason('ci', 'Pipeline must succeed before merge.'),
      );
    case 'ci_still_running':
      reasons.add(
        const MergeBlockedReason('ci_running', 'Pipeline is still running.'),
      );
      canAuto = !mr.draft && !mr.hasConflicts;
    case 'draft_status':
      if (!mr.draft) {
        reasons.add(
          const MergeBlockedReason(
            'draft',
            "Draft merge requests can't be merged — mark it ready first.",
          ),
        );
      }
    case 'need_rebase':
      reasons.add(
        const MergeBlockedReason(
          'need_rebase',
          'Branch must be rebased onto the target before merge.',
        ),
      );
      needsUpdate = true;
    case 'unchecked':
    case 'checking':
    case 'unchecked_pipeline':
      // Only hard-block when we have a sha (detail was loaded).
      if (mr.sha != null && mr.sha!.isNotEmpty) {
        reasons.add(
          const MergeBlockedReason(
            'mergeability_unknown',
            'Mergeability is still computing — try again in a moment.',
          ),
        );
      }
    case '':
      break;
    default:
      // Unknown status strings: do not invent a block when list is stale/empty.
      if (status.isNotEmpty &&
          status != 'preparing' &&
          mr.sha != null &&
          !['opened', 'locked'].contains(status)) {
        // Leave soft-open for unrecognized detailed statuses that aren't
        // clearly terminal-bad; still surface as info when clearly blocked.
      }
      break;
  }

  // Methods: GitLab UI offers merge (+ squash when policy allows). Rebase is
  // not a per-MR method in Magic Git (project-level).
  final methods = <MergeMethod>[MergeMethod.mergeCommit];
  final squashNever = policy?.squashNever ?? false;
  final squashAlways = policy?.squashAlways ?? false;
  if (!squashNever) {
    methods.add(MergeMethod.squash);
  }

  final defaultMethod = squashAlways || (policy?.squashEncouraged ?? false)
      ? (methods.contains(MergeMethod.squash)
            ? MergeMethod.squash
            : MergeMethod.mergeCommit)
      : MergeMethod.mergeCommit;

  final autoAlready = mr.mergeWhenPipelineSucceeds;
  final headSha = mr.sha;
  final pin = headSha != null && headSha.isNotEmpty;

  if (autoAlready) {
    canAuto = false;
  } else if (policy != null && !policy.autoMergeEnabled) {
    canAuto = false;
  } else if (mr.draft || mr.hasConflicts) {
    canAuto = false;
  }

  final hardBlockCodes = {
    'draft',
    'conflicts',
    'review',
    'discussions',
    'need_rebase',
    'ci', // hard fail pipeline requirement when status is ci_must_pass
  };
  final onlySoft =
      reasons.isNotEmpty &&
      reasons.every((r) => !hardBlockCodes.contains(r.code));
  if (onlySoft &&
      !mr.draft &&
      !autoAlready &&
      (policy == null || policy.autoMergeEnabled)) {
    canAuto = true;
  }

  final canNow = reasons.isEmpty && !autoAlready;

  return MergePlan(
    canMergeNow: canNow,
    canEnableAutoMerge: canAuto && !canNow,
    blockedReasons: reasons,
    allowedMethods: methods,
    defaultMethod: defaultMethod,
    defaultDeleteSource: policy?.removeSourceBranchAfterMerge ?? false,
    headSha: headSha,
    pinHeadSha: pin,
    supportsAdminBypass: false,
    autoMergeAlreadyEnabled: autoAlready,
    needsBranchUpdate: needsUpdate,
  );
}

/// Wire method name for `gh pr merge` / UI labels.
String mergeMethodFlag(MergeMethod m) => switch (m) {
  MergeMethod.mergeCommit => 'merge',
  MergeMethod.squash => 'squash',
  MergeMethod.rebase => 'rebase',
};

String mergeMethodLabel(MergeMethod m) => switch (m) {
  MergeMethod.mergeCommit => 'Create a merge commit',
  MergeMethod.squash => 'Squash and merge',
  MergeMethod.rebase => 'Rebase and merge',
};
