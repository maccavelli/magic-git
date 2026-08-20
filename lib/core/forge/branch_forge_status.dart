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

import '../git/branch_review_query.dart';
import '../github/models.dart';
import '../gitlab/models.dart';
import '../providers/app_providers.dart';
import '../providers/provider_retry_policy.dart';
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
      (k, pr) => MapEntry(k, (
        number: pr.number,
        url: pr.url,
        title: pr.title,
        draft: pr.draft,
      )),
    ),
    ciByBranch.map(
      (k, r) => MapEntry(k, (ci: _fromGh(r.runState), url: r.url)),
    ),
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
      (k, mr) => MapEntry(k, (
        number: mr.iid,
        url: mr.webUrl,
        title: mr.title,
        draft: mr.draft,
      )),
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
///
/// **Decorative use only.** Every failure mode collapses to `const {}` — no
/// forge, unknown forge, network down, auth expired, rate limited, and a repo
/// that genuinely has no open requests are indistinguishable, and `hasError`
/// is never true. That is fine for painting a badge (absent signal → no
/// badge) and wrong for anything that reasons about *absence*. Use
/// [branchForgeKnowledgeProvider] for that.
///
/// Kept independent of [branchForgeKnowledgeProvider] rather than delegating
/// to it: this is the provider ~14 widget-test harnesses override to keep
/// Browse offline, and delegating would route straight past those overrides.
/// Both read the same upstream list providers, so the duplication costs no
/// extra commands — only the `try` differs.
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
    }, retry: noProviderRetry);

/// Protected-branch rules for [repoPath], or an explicit "unknown".
///
/// Fails soft in the same shape as [branchForgeKnowledgeProvider]: any error
/// yields `known: false`, which every lookup reports as
/// [ProtectionKnowledge.unknown] rather than as "unprotected". The bulk-delete
/// preflight surfaces that as a warning instead of a silent green light.
///
/// Not registered in `repoScopedFetchFamilies` for the same reason as its
/// sibling: this file imports `app_providers.dart`, and its upstreams are
/// already registered.
final protectedBranchRulesProvider = FutureProvider.autoDispose
    .family<BranchProtectionRules, String>((ref, repoPath) async {
      final Forge forge;
      try {
        forge = await ref.watch(forgeProvider(repoPath).future);
      } catch (_) {
        return BranchProtectionRules.unavailable;
      }

      switch (forge) {
        case Forge.github:
          try {
            final names = await ref
                .watch(ghServiceProvider)
                .protectedBranchNames(repoPath);
            return BranchProtectionRules(names: names.toSet(), known: true);
          } catch (_) {
            return BranchProtectionRules.unavailable;
          }
        case Forge.gitlab:
          try {
            final patterns = await ref
                .watch(glabServiceProvider)
                .protectedBranchPatterns(repoPath);
            return BranchProtectionRules(patterns: patterns, known: true);
          } catch (_) {
            return BranchProtectionRules.unavailable;
          }
        case Forge.none:
          // No forge, so nothing can be forge-protected. A real answer.
          return const BranchProtectionRules(known: true);
        case Forge.unknown:
          return BranchProtectionRules.unavailable;
      }
    }, retry: noProviderRetry);

/// What we know about a repo's forge state — and whether we know it at all.
///
/// The distinction [branchForgeProvider] cannot express: "this branch has no
/// open request" is only true when the forge actually answered. A facet like
/// "No request" built on an empty-on-error map would list every branch in the
/// repo the moment the network blipped.
class BranchForgeKnowledge {
  final Map<String, BranchForge> byShortName;

  /// True only when a forge was identified AND both its request list and its
  /// CI list came back without throwing. An empty map with [known] true means
  /// "genuinely nothing open"; with [known] false it means "we have no idea".
  final bool known;

  final Forge forge;

  const BranchForgeKnowledge({
    this.byShortName = const {},
    this.known = false,
    this.forge = Forge.unknown,
  });

  /// Nothing was reachable.
  static const unavailable = BranchForgeKnowledge();
}

/// The typed sibling of [branchForgeProvider]: the same data, plus whether it
/// can be trusted.
///
/// `Forge.none` counts as **known**: a repo with no forge remote definitively
/// has no open requests, which is a real answer rather than a gap. Only a
/// detection failure, an unknown host, or a throwing list is `known: false`.
///
/// Deliberately absent from `repoScopedFetchFamilies`, like
/// [branchForgeProvider]: this file imports `app_providers.dart`, so
/// registering there would be a circular import — and it is unnecessary.
/// Every upstream (`forgeProvider`, the PR/MR lists, the CI lists) is
/// registered, and an autoDispose provider that watches them recomputes when
/// they are invalidated.
final branchForgeKnowledgeProvider = FutureProvider.autoDispose
    .family<BranchForgeKnowledge, String>((ref, repoPath) async {
      final Forge forge;
      try {
        forge = await ref.watch(forgeProvider(repoPath).future);
      } catch (_) {
        return BranchForgeKnowledge.unavailable;
      }

      switch (forge) {
        case Forge.github:
          try {
            final prs = await ref.watch(pullRequestsProvider(repoPath).future);
            final runs = await ref.watch(workflowRunsProvider(repoPath).future);
            return BranchForgeKnowledge(
              byShortName: _combineGithub(prs, runs),
              known: true,
              forge: forge,
            );
          } catch (_) {
            return BranchForgeKnowledge(forge: forge);
          }
        case Forge.gitlab:
          try {
            final mrs = await ref.watch(mergeRequestsProvider(repoPath).future);
            final pipes = await ref.watch(pipelinesProvider(repoPath).future);
            return BranchForgeKnowledge(
              byShortName: _combineGitlab(mrs, pipes),
              known: true,
              forge: forge,
            );
          } catch (_) {
            return BranchForgeKnowledge(forge: forge);
          }
        case Forge.none:
          return const BranchForgeKnowledge(known: true, forge: Forge.none);
        case Forge.unknown:
          return const BranchForgeKnowledge(forge: Forge.unknown);
      }
    }, retry: noProviderRetry);
