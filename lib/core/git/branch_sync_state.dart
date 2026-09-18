import 'git_service.dart';

/// A branch's sync state relative to its OWN upstream — deliberately a
/// separate axis from [BranchReviewSummary]'s ahead/behind-vs-review-base,
/// which compares against the review workspace's chosen base (often `main`),
/// not the branch's tracking remote. Conflating the two answers the wrong
/// question whenever they differ, which is the common case.
enum BranchSyncState {
  /// No upstream configured at all.
  noUpstream,

  /// Upstream was deleted on the remote (`GitRef.upstreamGone`).
  staleTracking,

  /// Ahead and behind both zero.
  upToDate,

  /// Ahead only — a fast-forward push would resolve it.
  aheadOnly,

  /// Behind only — a fast-forward pull/merge would resolve it.
  behindOnly,

  /// Both ahead and behind, with a common ancestor — the ordinary "have
  /// diverged" case: rebase, merge, or reset are all meaningful.
  diverged,

  /// Both ahead and behind, with NO common ancestor — same-name branches
  /// with genuinely unrelated content (a re-initialized repo, most often).
  unrelatedHistories,
}

/// The coarse (synchronous) classification — every value except the
/// diverged/unrelated-histories distinction, which needs an async
/// merge-base check. Callers needing that distinction call
/// [classifyBranchSyncStateAsync].
BranchSyncState classifyBranchSyncStateCoarse(GitRef branch) {
  if (branch.upstream == null) return BranchSyncState.noUpstream;
  if (branch.upstreamGone) return BranchSyncState.staleTracking;
  if (branch.ahead == 0 && branch.behind == 0) return BranchSyncState.upToDate;
  if (branch.ahead > 0 && branch.behind == 0) return BranchSyncState.aheadOnly;
  if (branch.ahead == 0 && branch.behind > 0) {
    return BranchSyncState.behindOnly;
  }
  // ahead > 0 && behind > 0 — provisionally diverged; the caller resolves the
  // unrelated-histories possibility asynchronously and may replace this.
  return BranchSyncState.diverged;
}

/// Resolves the diverged/unrelatedHistories distinction for a branch whose
/// coarse state is [BranchSyncState.diverged]. [refs] is the already-fetched
/// full ref list (local + remote-tracking) — the upstream's OID is looked up
/// there, costing no additional git call; only the ancestor check itself
/// (one `git merge-base`) is a new round trip, and only for branches that
/// are ahead-and-behind in the first place.
Future<BranchSyncState> classifyBranchSyncStateAsync(
  GitService git,
  String repoPath,
  GitRef branch,
  List<GitRef> refs,
) async {
  final coarse = classifyBranchSyncStateCoarse(branch);
  if (coarse != BranchSyncState.diverged) return coarse;
  final upstreamRef = refs
      .where((r) => r.isRemote && r.shortName == branch.upstream)
      .firstOrNull;
  if (upstreamRef == null) {
    return coarse; // shouldn't happen: ahead/behind implies a resolvable upstream
  }
  final related = await git.haveCommonAncestor(
    repoPath,
    branch.commitOid,
    upstreamRef.commitOid,
  );
  return related
      ? BranchSyncState.diverged
      : BranchSyncState.unrelatedHistories;
}
