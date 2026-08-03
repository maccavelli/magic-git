import '../forge/forge_json.dart';

/// A GitLab CI/CD pipeline or job status. The raw wire string is preserved on
/// the model for verbatim display; this typed view drives color/retry logic so
/// those switches are compile-exhaustive (a new GitLab status maps to [unknown]
/// rather than silently mis-coloring).
enum CiStatus {
  success,
  failed,
  running,
  pending,
  created,
  waitingForResource,
  preparing,
  scheduled,
  canceled,
  skipped,
  manual,
  unknown;

  static CiStatus fromWire(String raw) => switch (raw) {
    'success' => success,
    'failed' => failed,
    'running' => running,
    'pending' => pending,
    'created' => created,
    'waiting_for_resource' => waitingForResource,
    'preparing' => preparing,
    'scheduled' => scheduled,
    'canceled' => canceled,
    'skipped' => skipped,
    'manual' => manual,
    _ => unknown,
  };

  /// Whether a pipeline in this status belongs in the Inbox — it failed, is
  /// still moving toward a result, or is blocked on a manual action. The single
  /// source of truth for that judgement, so the Inbox filter can't drift from
  /// the status model: the old inline `{failed, running, pending}` check missed
  /// every other non-terminal state the wire actually emits (`created`,
  /// `waiting_for_resource`, `preparing`, `scheduled`, `manual`) — a pipeline
  /// stuck waiting for a runner never surfaced. Terminal and unrecognized
  /// states stay out.
  bool get needsAttention => switch (this) {
    failed ||
    running ||
    pending ||
    created ||
    waitingForResource ||
    preparing ||
    scheduled ||
    manual => true,
    success || canceled || skipped || unknown => false,
  };
}

/// A GitLab merge request, from `glab mr list/view --output json` (REST shape).
///
/// List responses are already fairly fat; we parse extra keys when present.
/// Detail-tier fields filled by [GlabService.mergeRequestDetail] when list
/// omits them (or they are stale).
class MergeRequest {
  final int iid;
  final String title;
  final String state; // opened / merged / closed / locked
  final String? authorUsername;
  final String sourceBranch;
  final String targetBranch;
  final String webUrl;
  final bool draft;

  // ---- List enrichment -----------------------------------------------------
  final List<String> labels;
  final List<String> assigneeUsernames;
  /// Prefer over deprecated [mergeStatus]. May be stale on list; null if absent.
  final String? detailedMergeStatus;
  /// Legacy `merge_status` fallback when `detailed_merge_status` is missing.
  final String? mergeStatus;
  final bool hasConflicts;
  /// Head SHA — often present on list; required for SHA-pinned merge.
  final String? sha;
  final bool mergeWhenPipelineSucceeds;
  final String? description;
  final bool? squash;
  final bool? shouldRemoveSourceBranch;
  final bool? userCanMerge;

  const MergeRequest({
    required this.iid,
    required this.title,
    required this.state,
    this.authorUsername,
    required this.sourceBranch,
    required this.targetBranch,
    required this.webUrl,
    required this.draft,
    this.labels = const [],
    this.assigneeUsernames = const [],
    this.detailedMergeStatus,
    this.mergeStatus,
    this.hasConflicts = false,
    this.sha,
    this.mergeWhenPipelineSucceeds = false,
    this.description,
    this.squash,
    this.shouldRemoveSourceBranch,
    this.userCanMerge,
  });

  String get shortSha => shortShaOf(sha);

  factory MergeRequest.fromJson(Map<String, dynamic> json) {
    final author = json['author'];
    final user = json['user'];
    return MergeRequest(
      iid: (json['iid'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      state: json['state'] as String? ?? '',
      authorUsername: author is Map ? author['username'] as String? : null,
      sourceBranch: json['source_branch'] as String? ?? '',
      targetBranch: json['target_branch'] as String? ?? '',
      webUrl: json['web_url'] as String? ?? '',
      // GitLab exposes drafts via either `draft` or the legacy
      // `work_in_progress` field depending on version.
      draft:
          (json['draft'] as bool?) ??
          (json['work_in_progress'] as bool?) ??
          false,
      labels: _parseLabels(json['labels']),
      assigneeUsernames: _parseAssignees(json),
      detailedMergeStatus: _emptyToNull(
        json['detailed_merge_status'] as String?,
      ),
      mergeStatus: _emptyToNull(json['merge_status'] as String?),
      hasConflicts: (json['has_conflicts'] as bool?) ?? false,
      sha: json['sha'] as String?,
      mergeWhenPipelineSucceeds:
          (json['merge_when_pipeline_succeeds'] as bool?) ?? false,
      description: json['description'] as String?,
      squash: json['squash'] as bool? ?? json['squash_on_merge'] as bool?,
      shouldRemoveSourceBranch:
          json['should_remove_source_branch'] as bool?,
      userCanMerge: user is Map ? user['can_merge'] as bool? : null,
    );
  }

  static String? _emptyToNull(String? s) =>
      (s == null || s.isEmpty) ? null : s;

  /// GitLab list/view may send bare name strings or `{name}` / `{title}` objects.
  static List<String> _parseLabels(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) {
          if (e is String) return e;
          if (e is Map) {
            return (e['name'] as String?) ?? (e['title'] as String?) ?? '';
          }
          return '';
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static List<String> _parseAssignees(Map<String, dynamic> json) {
    final assignees = json['assignees'];
    if (assignees is List) {
      final names = assignees
          .map((e) => e is Map ? e['username'] as String? : null)
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
      if (names.isNotEmpty) return names;
    }
    final single = json['assignee'];
    if (single is Map) {
      final u = single['username'] as String?;
      if (u != null && u.isNotEmpty) return [u];
    }
    return const [];
  }
}

/// A CI/CD pipeline, from `glab api projects/:id/pipelines`.
class Pipeline {
  final int id;
  final String status; // success / failed / running / pending / canceled ...
  final String ref;
  final String? sha;
  final String webUrl;
  final String? source;

  const Pipeline({
    required this.id,
    required this.status,
    required this.ref,
    this.sha,
    required this.webUrl,
    this.source,
  });

  factory Pipeline.fromJson(Map<String, dynamic> json) {
    return Pipeline(
      id: (json['id'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? '',
      ref: json['ref'] as String? ?? '',
      sha: json['sha'] as String?,
      webUrl: json['web_url'] as String? ?? '',
      source: json['source'] as String?,
    );
  }

  String get shortSha => shortShaOf(sha);

  /// Typed view of [status] for color/logic (see [CiStatus]).
  CiStatus get ciStatus => CiStatus.fromWire(status);

  /// A finished-but-unsuccessful pipeline the user can retry.
  bool get isRetryable =>
      ciStatus == CiStatus.failed || ciStatus == CiStatus.canceled;
}

// The project-dashboard models (Issue, Label, Milestone, Release,
// ProjectDashboard) moved to the forge-neutral `ForgeIssue`/`ForgeLabel`/
// `ForgeMilestone`/`ForgeRelease`/`ForgeProjectDashboard` in
// `core/forge/forge_dashboard.dart` — they were structurally identical to
// their GitHub twins, differing only in wire field names.

/// A CI/CD job within a pipeline, from `glab api .../pipelines/:id/jobs`.
class Job {
  final int id;
  final String name;
  final String stage;
  final String status; // success / failed / running / pending / manual ...

  const Job({
    required this.id,
    required this.name,
    required this.stage,
    required this.status,
  });

  factory Job.fromJson(Map<String, dynamic> json) => Job(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    stage: json['stage'] as String? ?? '',
    status: json['status'] as String? ?? '',
  );

  /// Typed view of [status] for color/logic (see [CiStatus]).
  CiStatus get ciStatus => CiStatus.fromWire(status);
}
