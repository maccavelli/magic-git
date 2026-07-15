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
}

/// A GitLab merge request, from `glab mr list --output json`.
class MergeRequest {
  final int iid;
  final String title;
  final String state; // opened / merged / closed / locked
  final String? authorUsername;
  final String sourceBranch;
  final String targetBranch;
  final String webUrl;
  final bool draft;

  const MergeRequest({
    required this.iid,
    required this.title,
    required this.state,
    this.authorUsername,
    required this.sourceBranch,
    required this.targetBranch,
    required this.webUrl,
    required this.draft,
  });

  factory MergeRequest.fromJson(Map<String, dynamic> json) {
    final author = json['author'];
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
    );
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
