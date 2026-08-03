/// GitHub domain models, parsed from the `gh` CLI's `--json` output and its
/// `gh api` / `gh api graphql` passthrough. Deliberately parallel to
/// `lib/core/gitlab/models.dart` (the GitLab equivalents) so the two forge
/// panels stay structurally identical — but the field names follow GitHub's
/// own vocabulary: a **pull request** has a `number` (not an `iid`),
/// `headRefName`/`baseRefName` (not source/target), and CI is a **workflow
/// run** whose state is a *pair* of fields (`status` + `conclusion`) rather
/// than GitLab's single `status`.
library;

import '../forge/forge_json.dart';

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

  /// Whether a run in this state belongs in the Inbox — it's failed, still
  /// moving, or waiting on a human. The single source of truth for that
  /// judgement, so the Inbox filter can't drift from the state model: reading
  /// the raw `conclusion`/`status` strings inline (as it once did) silently
  /// missed `startup_failure`/`timed_out` (both → [failure] here) and the
  /// `requested`/`waiting` live states (→ [pending]). Terminal-good and
  /// unrecognized states stay out.
  bool get needsAttention => switch (this) {
    failure || running || pending || actionRequired => true,
    success || canceled || skipped || neutral || unknown => false,
  };
}

/// GitHub GraphQL / `gh --json` mergeability for a PR. Distinct from REST's
/// bool|null: `gh` emits the strings `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`.
enum GhMergeable {
  mergeable,
  conflicting,
  unknown;

  static GhMergeable fromWire(dynamic raw) {
    final s = (raw?.toString() ?? '').toUpperCase();
    return switch (s) {
      'MERGEABLE' || 'TRUE' => GhMergeable.mergeable,
      'CONFLICTING' || 'FALSE' => GhMergeable.conflicting,
      _ => GhMergeable.unknown,
    };
  }
}

/// A GitHub pull request, from `gh pr list/view --json …`.
///
/// List-tier fields are always populated when the list query requests them.
/// Detail-tier fields ([body], [headOid], [mergeable], …) are null/default on
/// list rows and filled by [GhService.pullRequestDetail].
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

  // ---- List enrichment (cheap) ---------------------------------------------
  /// Label names (colors available via [labelColors] when the wire sent them).
  final List<String> labels;
  /// Parallel to [labels] when `gh` sent `{name,color}` objects; empty strings
  /// when only a name is known. Same length as [labels] when non-empty.
  final List<String> labelColors;
  final List<String> assigneeLogins;
  /// `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED` / empty / null.
  final String? reviewDecision;
  final String? milestoneTitle;

  // ---- Detail tier (nullable on list rows) ---------------------------------
  final String? body;
  /// Head commit OID (`headRefOid` from `gh`). Required for SHA-pinned merge.
  final String? headOid;
  final String? baseOid;
  final GhMergeable mergeable;
  /// e.g. CLEAN / DIRTY / BLOCKED / BEHIND / UNSTABLE / …
  final String? mergeStateStatus;
  final bool autoMergeEnabled;
  final String? autoMergeMethod;
  final int? additions;
  final int? deletions;
  final int? changedFiles;

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
    this.labels = const [],
    this.labelColors = const [],
    this.assigneeLogins = const [],
    this.reviewDecision,
    this.milestoneTitle,
    this.body,
    this.headOid,
    this.baseOid,
    this.mergeable = GhMergeable.unknown,
    this.mergeStateStatus,
    this.autoMergeEnabled = false,
    this.autoMergeMethod,
    this.additions,
    this.deletions,
    this.changedFiles,
  });

  String get shortHeadOid => shortShaOf(headOid);

  factory PullRequest.fromJson(Map<String, dynamic> json) {
    // `gh pr list --json state` reports OPEN/CLOSED/MERGED (uppercase); a merged
    // PR carries state MERGED rather than a separate boolean in the list view.
    final state = (json['state'] as String? ?? '').toLowerCase();
    final author = json['author'];
    final (labels, labelColors) = _parseGhLabels(json['labels']);
    final assignees = _parseLogins(json['assignees']);
    final milestone = json['milestone'];
    final autoMerge = json['autoMergeRequest'];
    String? autoMethod;
    if (autoMerge is Map) {
      autoMethod = autoMerge['mergeMethod'] as String?;
    }
    // Prefer GraphQL headRefOid; tolerate REST-shaped head.sha if present.
    final head = json['head'];
    final base = json['base'];
    final headOid =
        json['headRefOid'] as String? ??
        (head is Map ? head['sha'] as String? : null) ??
        json['headSha'] as String?;
    final baseOid =
        json['baseRefOid'] as String? ??
        (base is Map ? base['sha'] as String? : null);

    return PullRequest(
      number: (json['number'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      state: state,
      merged: (json['merged'] as bool?) ?? (state == 'merged'),
      draft: (json['isDraft'] as bool?) ?? (json['draft'] as bool?) ?? false,
      authorLogin: author is Map ? author['login'] as String? : null,
      headRefName: json['headRefName'] as String? ??
          (head is Map ? head['ref'] as String? : null) ??
          '',
      baseRefName: json['baseRefName'] as String? ??
          (base is Map ? base['ref'] as String? : null) ??
          '',
      url: json['url'] as String? ?? json['html_url'] as String? ?? '',
      labels: labels,
      labelColors: labelColors,
      assigneeLogins: assignees,
      reviewDecision: _emptyToNull(json['reviewDecision'] as String?),
      milestoneTitle: milestone is Map
          ? milestone['title'] as String?
          : milestone is String
          ? milestone
          : null,
      body: json['body'] as String?,
      headOid: headOid,
      baseOid: baseOid,
      mergeable: GhMergeable.fromWire(json['mergeable']),
      mergeStateStatus: _emptyToNull(
        (json['mergeStateStatus'] as String?) ??
            (json['mergeable_state'] as String?),
      ),
      autoMergeEnabled: autoMerge != null && autoMerge is! bool
          ? true
          : (autoMerge as bool?) ?? false,
      autoMergeMethod: autoMethod,
      additions: (json['additions'] as num?)?.toInt(),
      deletions: (json['deletions'] as num?)?.toInt(),
      changedFiles: (json['changedFiles'] as num?)?.toInt() ??
          (json['changed_files'] as num?)?.toInt(),
    );
  }

  static String? _emptyToNull(String? s) =>
      (s == null || s.isEmpty) ? null : s;

  static (List<String>, List<String>) _parseGhLabels(dynamic raw) {
    if (raw is! List) return (const [], const []);
    final names = <String>[];
    final colors = <String>[];
    for (final e in raw) {
      if (e is String) {
        if (e.isEmpty) continue;
        names.add(e);
        colors.add('');
      } else if (e is Map) {
        final name = e['name'] as String? ?? '';
        if (name.isEmpty) continue;
        names.add(name);
        colors.add(e['color'] as String? ?? '');
      }
    }
    return (names, colors);
  }

  static List<String> _parseLogins(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? e['login'] as String? : e as String?)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
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

  String get shortSha => shortShaOf(headSha);

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
