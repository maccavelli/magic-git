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

  String get shortSha =>
      sha == null ? '' : sha!.substring(0, sha!.length.clamp(0, 8));

  /// Typed view of [status] for color/logic (see [CiStatus]).
  CiStatus get ciStatus => CiStatus.fromWire(status);

  /// A finished-but-unsuccessful pipeline the user can retry.
  bool get isRetryable =>
      ciStatus == CiStatus.failed || ciStatus == CiStatus.canceled;
}

/// A project label, from `glab api projects/:id/labels`.
class Label {
  final String name;
  final String color; // Hex, e.g. "#FF0000"
  final String? description;

  const Label({required this.name, required this.color, this.description});

  factory Label.fromJson(Map<String, dynamic> json) => Label(
    name: json['name'] as String? ?? '',
    color: json['color'] as String? ?? '#888888',
    description: json['description'] as String?,
  );
}

/// A project milestone.
class Milestone {
  final int iid;
  final String title;
  final String state; // active / closed
  final String? dueDate;

  const Milestone({
    required this.iid,
    required this.title,
    required this.state,
    this.dueDate,
  });

  factory Milestone.fromJson(Map<String, dynamic> json) => Milestone(
    iid: (json['iid'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    state: json['state'] as String? ?? '',
    dueDate: json['due_date'] as String?,
  );
}

/// A project release.
class Release {
  final String tagName;
  final String name;
  final String? createdAt;

  const Release({required this.tagName, required this.name, this.createdAt});

  factory Release.fromJson(Map<String, dynamic> json) => Release(
    tagName: json['tag_name'] as String? ?? '',
    name: json['name'] as String? ?? '',
    createdAt: json['created_at'] as String?,
  );
}

/// A project issue.
class Issue {
  final int iid;
  final String title;
  final String state; // opened / closed
  final String? authorUsername;
  final List<String> labels;

  const Issue({
    required this.iid,
    required this.title,
    required this.state,
    this.authorUsername,
    this.labels = const [],
  });

  factory Issue.fromJson(Map<String, dynamic> json) {
    final author = json['author'];
    final rawLabels = json['labels'];
    return Issue(
      iid: (json['iid'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      state: json['state'] as String? ?? '',
      authorUsername: author is Map ? author['username'] as String? : null,
      labels: rawLabels is List
          ? rawLabels.whereType<String>().toList()
          : const [],
    );
  }
}

/// Combined project overview fetched in one GraphQL round-trip.
class ProjectDashboard {
  final List<Issue> issues;
  final List<Label> labels;
  final List<Milestone> milestones;
  final List<Release> releases;

  const ProjectDashboard({
    this.issues = const [],
    this.labels = const [],
    this.milestones = const [],
    this.releases = const [],
  });
}

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
