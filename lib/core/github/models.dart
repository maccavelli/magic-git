/// GitHub domain models, parsed from the `gh` CLI's `--json` output and its
/// `gh api` / `gh api graphql` passthrough. Deliberately parallel to
/// `lib/core/gitlab/models.dart` (the GitLab equivalents) so the two forge
/// panels stay structurally identical — but the field names follow GitHub's
/// own vocabulary: a **pull request** has a `number` (not an `iid`),
/// `headRefName`/`baseRefName` (not source/target), and CI is a **workflow
/// run** whose state is a *pair* of fields (`status` + `conclusion`) rather
/// than GitLab's single `status`.
library;

/// A unified, typed view of a GitHub Actions run/job state, collapsing the
/// (`status`, `conclusion`) pair into one enum for color/retry logic — so those
/// switches are compile-exhaustive (a new GitHub state maps to [unknown] rather
/// than silently mis-coloring), mirroring GitLab's [CiStatus].
///
/// GitHub models CI in two fields: `status` is the lifecycle
/// (`queued`/`in_progress`/`completed`), and `conclusion` is only meaningful
/// once `status == completed` (`success`/`failure`/`cancelled`/…).
enum GhRunState {
  success,
  failure,
  running,
  pending,
  canceled,
  skipped,
  actionRequired,
  neutral,
  unknown;

  /// Collapses GitHub's (`status`, `conclusion`) pair into one state. While a
  /// run is still going (`status != completed`) `conclusion` is null/empty and
  /// the lifecycle drives the result; once completed, `conclusion` does.
  static GhRunState from(String status, String? conclusion) {
    switch (status) {
      case 'completed':
        return switch (conclusion) {
          'success' => GhRunState.success,
          'failure' || 'startup_failure' || 'timed_out' => GhRunState.failure,
          'cancelled' || 'canceled' => GhRunState.canceled,
          'skipped' || 'stale' => GhRunState.skipped,
          'action_required' => GhRunState.actionRequired,
          'neutral' => GhRunState.neutral,
          _ => GhRunState.unknown,
        };
      case 'in_progress':
        return GhRunState.running;
      case 'queued' || 'requested' || 'waiting' || 'pending':
        return GhRunState.pending;
      default:
        return GhRunState.unknown;
    }
  }
}

/// A GitHub pull request, from `gh pr list/view --json …`.
class PullRequest {
  final int number;
  final String title;
  final String state; // open / closed / merged
  final bool merged;
  final bool draft;
  final String? authorLogin;
  final String headRefName;
  final String baseRefName;
  final String url;

  const PullRequest({
    required this.number,
    required this.title,
    required this.state,
    required this.merged,
    required this.draft,
    this.authorLogin,
    required this.headRefName,
    required this.baseRefName,
    required this.url,
  });

  factory PullRequest.fromJson(Map<String, dynamic> json) {
    // `gh pr list --json state` reports OPEN/CLOSED/MERGED (uppercase); a merged
    // PR carries state MERGED rather than a separate boolean in the list view.
    final state = (json['state'] as String? ?? '').toLowerCase();
    final author = json['author'];
    return PullRequest(
      number: (json['number'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      state: state,
      merged: (json['merged'] as bool?) ?? (state == 'merged'),
      draft: (json['isDraft'] as bool?) ?? (json['draft'] as bool?) ?? false,
      authorLogin: author is Map ? author['login'] as String? : null,
      headRefName: json['headRefName'] as String? ?? '',
      baseRefName: json['baseRefName'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }
}

/// A GitHub Actions workflow run, from `gh run list --json …`.
class WorkflowRun {
  final int id; // databaseId
  final String status; // queued / in_progress / completed
  final String? conclusion; // success / failure / … (null while running)
  final String headBranch;
  final String? headSha;
  final String workflowName;
  final String? event;
  final String url;

  const WorkflowRun({
    required this.id,
    required this.status,
    this.conclusion,
    required this.headBranch,
    this.headSha,
    required this.workflowName,
    this.event,
    required this.url,
  });

  factory WorkflowRun.fromJson(Map<String, dynamic> json) {
    // gh emits an empty-string conclusion for in-flight runs; normalize to null.
    final rawConclusion = json['conclusion'] as String?;
    return WorkflowRun(
      id: (json['databaseId'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? '',
      conclusion: (rawConclusion == null || rawConclusion.isEmpty)
          ? null
          : rawConclusion,
      headBranch: json['headBranch'] as String? ?? '',
      headSha: json['headSha'] as String?,
      workflowName: json['workflowName'] as String? ?? '',
      event: json['event'] as String?,
      url: json['url'] as String? ?? '',
    );
  }

  String get shortSha =>
      headSha == null ? '' : headSha!.substring(0, headSha!.length.clamp(0, 8));

  /// Typed view of (`status`, `conclusion`) for color/logic (see [GhRunState]).
  GhRunState get runState => GhRunState.from(status, conclusion);

  /// A finished-but-unsuccessful run the user can re-run.
  bool get isRerunnable =>
      runState == GhRunState.failure || runState == GhRunState.canceled;
}

/// A job within a workflow run, from
/// `gh api repos/{owner}/{repo}/actions/runs/:id/jobs` (the `jobs[]` array).
class GhJob {
  final int id;
  final String name;
  final String status; // queued / in_progress / completed
  final String? conclusion;

  const GhJob({
    required this.id,
    required this.name,
    required this.status,
    this.conclusion,
  });

  factory GhJob.fromJson(Map<String, dynamic> json) {
    final rawConclusion = json['conclusion'] as String?;
    return GhJob(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      conclusion: (rawConclusion == null || rawConclusion.isEmpty)
          ? null
          : rawConclusion,
    );
  }

  GhRunState get runState => GhRunState.from(status, conclusion);
}

// The project-dashboard models (GhIssue, GhLabel, GhMilestone, GhRelease,
// GhProjectDashboard) moved to the forge-neutral `ForgeIssue`/`ForgeLabel`/
// `ForgeMilestone`/`ForgeRelease`/`ForgeProjectDashboard` in
// `core/forge/forge_dashboard.dart` — they were structurally identical to
// their GitLab twins, differing only in wire field names. GitHub's bare-hex
// label-color normalization lives there too, as `normalizeLabelColor`.
