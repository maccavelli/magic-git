/// Per-branch forge status for the Branches tab: fuses a local branch to its
/// open pull/merge request and its latest CI run, so a row can show a `#N`
/// chip + a CI dot and the detail pane can offer "Open PR". Forge-neutral —
/// [branchForgeProvider] dispatches on [forgeProvider] and reuses the same
/// PR/MR + CI providers the Forge tab already drives (no new network calls of
/// its own), keyed by branch name via the request's source branch / the run's
/// head branch. Everything degrades to an empty map (never throws) so the
/// branch list renders instantly and the forge signal pops in when it lands.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../github/models.dart';
import '../gitlab/models.dart';
import '../providers/app_providers.dart';
import 'forge.dart';

/// A unified CI state across GitHub workflow runs and GitLab pipelines — the
/// forge-specific enums ([GhRunState], [CiStatus]) collapsed to what a single
/// dot needs to convey.
enum ForgeCi { success, failure, running, canceled, skipped, unknown }

/// What a branch's open request + latest CI look like. Either half may be
/// absent (a branch can have CI with no PR, or a PR with no recent run).
class BranchForge {
  /// PR number (GitHub) or MR iid (GitLab); null when the branch has none open.
  final int? requestNumber;
  final String? requestUrl;
  final String? requestTitle;
  final bool requestDraft;

  /// true = GitLab merge request (`!N`), false = GitHub pull request (`#N`).
  final bool isMr;

  /// Latest CI for the branch, or null when none was found in the recent page.
  final ForgeCi? ci;
  final String? ciUrl;

  const BranchForge({
    this.requestNumber,
    this.requestUrl,
    this.requestTitle,
    this.requestDraft = false,
    this.isMr = false,
    this.ci,
    this.ciUrl,
  });

  bool get hasRequest => requestNumber != null;

  /// `#42` for a PR, `!42` for an MR.
  String get requestLabel => '${isMr ? '!' : '#'}$requestNumber';
}

ForgeCi _fromGh(GhRunState s) => switch (s) {
  GhRunState.success => ForgeCi.success,
  GhRunState.failure => ForgeCi.failure,
  GhRunState.running || GhRunState.pending => ForgeCi.running,
  GhRunState.canceled => ForgeCi.canceled,
  GhRunState.skipped || GhRunState.neutral => ForgeCi.skipped,
  GhRunState.actionRequired || GhRunState.unknown => ForgeCi.unknown,
};

ForgeCi _fromGl(CiStatus s) => switch (s) {
  CiStatus.success => ForgeCi.success,
  CiStatus.failed => ForgeCi.failure,
  CiStatus.running ||
  CiStatus.pending ||
  CiStatus.created ||
  CiStatus.waitingForResource ||
  CiStatus.preparing ||
  CiStatus.scheduled ||
  CiStatus.manual => ForgeCi.running,
  CiStatus.canceled => ForgeCi.canceled,
  CiStatus.skipped => ForgeCi.skipped,
  CiStatus.unknown => ForgeCi.unknown,
};

Map<String, BranchForge> _combineGithub(
  List<PullRequest> prs,
  List<WorkflowRun> runs,
) {
  final prByBranch = <String, PullRequest>{};
  for (final pr in prs) {
    if (pr.state != 'open') continue;
    prByBranch.putIfAbsent(pr.headRefName, () => pr);
  }
  // gh run list is newest-first — first entry per branch wins.
  final ciByBranch = <String, WorkflowRun>{};
  for (final r in runs) {
    if (r.headBranch.isEmpty) continue;
    ciByBranch.putIfAbsent(r.headBranch, () => r);
  }
  return _merge(
    prByBranch.map(
      (k, pr) => MapEntry(
        k,
        (number: pr.number, url: pr.url, title: pr.title, draft: pr.draft),
      ),
    ),
    ciByBranch.map((k, r) => MapEntry(k, (ci: _fromGh(r.runState), url: r.url))),
    isMr: false,
  );
}

Map<String, BranchForge> _combineGitlab(
  List<MergeRequest> mrs,
  List<Pipeline> pipes,
) {
  final mrByBranch = <String, MergeRequest>{};
  for (final mr in mrs) {
    if (mr.state != 'opened') continue;
    mrByBranch.putIfAbsent(mr.sourceBranch, () => mr);
  }
  final ciByBranch = <String, Pipeline>{};
  for (final p in pipes) {
    if (p.ref.isEmpty) continue;
    ciByBranch.putIfAbsent(p.ref, () => p);
  }
  return _merge(
    mrByBranch.map(
      (k, mr) => MapEntry(
        k,
        (number: mr.iid, url: mr.webUrl, title: mr.title, draft: mr.draft),
      ),
    ),
    ciByBranch.map(
      (k, p) => MapEntry(k, (ci: _fromGl(p.ciStatus), url: p.webUrl)),
    ),
    isMr: true,
  );
}

Map<String, BranchForge> _merge(
  Map<String, ({int number, String url, String title, bool draft})> requests,
  Map<String, ({ForgeCi ci, String url})> ci, {
  required bool isMr,
}) {
  final keys = {...requests.keys, ...ci.keys};
  return {
    for (final k in keys)
      k: BranchForge(
        requestNumber: requests[k]?.number,
        requestUrl: requests[k]?.url,
        requestTitle: requests[k]?.title,
        requestDraft: requests[k]?.draft ?? false,
        isMr: isMr,
        ci: ci[k]?.ci,
        ciUrl: ci[k]?.url,
      ),
  };
}

/// Branch-name → [BranchForge] for [repoPath]. Empty for a repo with no forge
/// (or while auth/data is still resolving, or on any error). Watches the same
/// PR/MR + CI providers the Forge tab uses, so it shares their cache and
/// refresh rather than issuing its own calls.
final branchForgeProvider = FutureProvider.autoDispose
    .family<Map<String, BranchForge>, String>((ref, repoPath) async {
      try {
        final forge = await ref.watch(forgeProvider(repoPath).future);
        switch (forge) {
          case Forge.github:
            final prs = await ref.watch(pullRequestsProvider(repoPath).future);
            final runs = await ref.watch(workflowRunsProvider(repoPath).future);
            return _combineGithub(prs, runs);
          case Forge.gitlab:
            final mrs = await ref.watch(mergeRequestsProvider(repoPath).future);
            final pipes = await ref.watch(pipelinesProvider(repoPath).future);
            return _combineGitlab(mrs, pipes);
          case Forge.none:
          case Forge.unknown:
            return const {};
        }
      } catch (_) {
        // Forge unreachable / unauthenticated / no remote — no signal, no error.
        return const {};
      }
    });
