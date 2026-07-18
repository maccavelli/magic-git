/// Forge-neutral project-dashboard models, following the `ForgeRepoSummary`
/// precedent: one class per concept with a `fromGh…`/`fromGlab…` factory per
/// forge. These replaced the structurally identical twins
/// `GhIssue`/`Issue`, `GhLabel`/`Label`, `GhMilestone`/`Milestone`,
/// `GhRelease`/`Release`, and `GhProjectDashboard`/`ProjectDashboard`, whose
/// only differences were field names on the wire (`number` vs `iid`, `name`
/// vs `title`, `dueOn` vs `dueDate`, `publishedAt` vs `releasedAt`) — exactly
/// what a per-forge factory absorbs.
library;

import 'forge_json.dart';

/// Normalizes a label color to a `#RRGGBB` hex string. GitHub returns label
/// colors as a bare 6-hex string with no leading `#` (e.g. `d73a4a`); GitLab
/// already sends the `#`-prefixed form the UI's color parser expects.
String normalizeLabelColor(String? raw) {
  if (raw == null || raw.isEmpty) return '#888888';
  return raw.startsWith('#') ? raw : '#$raw';
}

/// An open issue on the forge.
class ForgeIssue {
  /// The user-visible issue number: GitHub `number`, GitLab `iid`. Null when
  /// the forge didn't report a parseable number (see [jsonIntOrNull]).
  final int? id;
  final String title;

  /// Lowercased wire state (`open`/`closed` on GitHub, `opened`/`closed` on
  /// GitLab); the dashboard only fetches open ones.
  final String state;

  /// Author login/username, when the forge reported one.
  final String? author;
  final List<String> labels;

  /// The issue description/body. Null on list rows (the list queries don't
  /// carry it) — populated only by a single-issue detail fetch (see
  /// [ForgeIssue.fromGlabCli] / [ForgeIssue.fromGhCli]).
  final String? body;

  const ForgeIssue({
    required this.id,
    required this.title,
    required this.state,
    this.author,
    this.labels = const [],
    this.body,
  });

  /// From a GitHub GraphQL `Issue` node.
  factory ForgeIssue.fromGhGql(Map<String, dynamic> n) {
    final author = n['author'];
    return ForgeIssue(
      id: jsonIntOrNull(n['number']),
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'open').toLowerCase(),
      author: author is Map ? author['login'] as String? : null,
      labels: _labelNames(n['labels'], 'name'),
    );
  }

  /// From a GitLab GraphQL `Issue` node. `iid` arrives as a **String**
  /// (`"606072"`) — see [jsonIntOrNull].
  factory ForgeIssue.fromGlabGql(Map<String, dynamic> n) {
    final author = n['author'];
    return ForgeIssue(
      id: jsonIntOrNull(n['iid']),
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'opened').toLowerCase(),
      author: author is Map ? author['username'] as String? : null,
      labels: _labelNames(n['labels'], 'title'),
    );
  }

  /// From a `glab issue list` / `glab issue view -F json` object (GitLab REST
  /// shape, distinct from the GraphQL dashboard node): `iid` is a number,
  /// `labels` a bare array of name strings, `author` an object with
  /// `username`. [body] comes from `description`, present on a single-issue
  /// `view` and absent (→ null) on list rows.
  factory ForgeIssue.fromGlabCli(Map<String, dynamic> n) {
    final author = n['author'];
    return ForgeIssue(
      id: jsonIntOrNull(n['iid']),
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'opened').toLowerCase(),
      author: author is Map ? author['username'] as String? : null,
      labels: _cliLabelNames(n['labels']),
      body: (n['description'] as String?)?.trimRight(),
    );
  }

  /// From a `gh issue list` / `gh issue view --json` object (GitHub CLI shape):
  /// `number`, `labels` an array of `{name}` objects, `author` an object with
  /// `login`. [body] comes from the `body` field, requested only for the
  /// single-issue detail view.
  factory ForgeIssue.fromGhCli(Map<String, dynamic> n) {
    final author = n['author'];
    return ForgeIssue(
      id: jsonIntOrNull(n['number']),
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'open').toLowerCase(),
      author: author is Map ? author['login'] as String? : null,
      labels: _cliLabelNames(n['labels']),
      body: (n['body'] as String?)?.trimRight(),
    );
  }

  /// The names inside an issue's nested label connection — GitHub calls the
  /// name field `name`, GitLab `title`.
  static List<String> _labelNames(dynamic connection, String field) =>
      graphqlNodes(connection, (l) => l[field] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

  /// Label names from a REST/CLI `labels` array — GitLab issues send bare name
  /// strings (`["bug","ui"]`), GitHub sends `{name}` objects. Handles both and
  /// drops blanks.
  static List<String> _cliLabelNames(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e is String ? e : (e is Map ? e['name'] as String? : null))
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

/// A project/repository label. [color] is normalized to `#RRGGBB` (see
/// [normalizeLabelColor]).
class ForgeLabel {
  final String name;
  final String color;
  final String? description;

  const ForgeLabel({required this.name, required this.color, this.description});

  /// From a GitHub GraphQL `Label` node (bare-hex color).
  factory ForgeLabel.fromGhGql(Map<String, dynamic> n) => ForgeLabel(
    name: n['name'] as String? ?? '',
    color: normalizeLabelColor(n['color'] as String?),
    description: n['description'] as String?,
  );

  /// From a GitLab GraphQL `Label` node (`title` is the name; color is
  /// already `#`-prefixed, but normalize anyway).
  factory ForgeLabel.fromGlabGql(Map<String, dynamic> n) => ForgeLabel(
    name: n['title'] as String? ?? '',
    color: normalizeLabelColor(n['color'] as String?),
    description: n['description'] as String?,
  );
}

/// An open/active milestone.
class ForgeMilestone {
  /// The user-visible milestone number: GitHub `number`, GitLab `iid`. Null
  /// when the forge didn't report a parseable number (see [jsonIntOrNull]);
  /// the milestone picker skips such entries since it can't key on them.
  final int? id;
  final String title;

  /// Lowercased wire state (`open` on GitHub, `active` on GitLab).
  final String state;

  /// Due date as `YYYY-MM-DD`, when set. GitHub's `dueOn` is a full ISO
  /// timestamp — normalized to the date here so the UI never re-parses;
  /// GitLab's `dueDate` is already date-only.
  final String? due;

  /// The milestone description. Null on the GraphQL dashboard nodes (not
  /// fetched there) — populated by the REST list factories
  /// ([ForgeMilestone.fromGlabRest] / [ForgeMilestone.fromGhRest]).
  final String? description;

  const ForgeMilestone({
    required this.id,
    required this.title,
    required this.state,
    this.due,
    this.description,
  });

  /// From a GitHub GraphQL `Milestone` node.
  factory ForgeMilestone.fromGhGql(Map<String, dynamic> n) => ForgeMilestone(
    id: jsonIntOrNull(n['number']),
    title: n['title'] as String? ?? '',
    state: (n['state'] as String? ?? 'open').toLowerCase(),
    due: _dateOnly(n['dueOn'] as String?),
  );

  /// From a GitLab GraphQL `Milestone` node. `iid` arrives as a **String** —
  /// see [jsonIntOrNull].
  factory ForgeMilestone.fromGlabGql(Map<String, dynamic> n) => ForgeMilestone(
    id: jsonIntOrNull(n['iid']),
    title: n['title'] as String? ?? '',
    state: (n['state'] as String? ?? 'active').toLowerCase(),
    due: _dateOnly(n['dueDate'] as String?),
  );

  /// From a `glab api projects/:id/milestones` REST object: `iid` is a number,
  /// `state` active/closed, `due_date` already date-only, plus `description`.
  factory ForgeMilestone.fromGlabRest(Map<String, dynamic> n) => ForgeMilestone(
    id: jsonIntOrNull(n['iid']),
    title: n['title'] as String? ?? '',
    state: (n['state'] as String? ?? 'active').toLowerCase(),
    due: _dateOnly(n['due_date'] as String?),
    description: (n['description'] as String?)?.trimRight(),
  );

  /// From a `gh api repos/{owner}/{repo}/milestones` REST object: `number`,
  /// `state` open/closed, `due_on` a full ISO timestamp (→ date-only), plus
  /// `description`.
  factory ForgeMilestone.fromGhRest(Map<String, dynamic> n) => ForgeMilestone(
    id: jsonIntOrNull(n['number']),
    title: n['title'] as String? ?? '',
    state: (n['state'] as String? ?? 'open').toLowerCase(),
    due: _dateOnly(n['due_on'] as String?),
    description: (n['description'] as String?)?.trimRight(),
  );
}

/// A release/tag published on the forge.
class ForgeRelease {
  final String tagName;
  final String name;

  /// ISO-8601 publish timestamp: GitHub `publishedAt`, GitLab `releasedAt`.
  final String? publishedAt;

  const ForgeRelease({
    required this.tagName,
    required this.name,
    this.publishedAt,
  });

  /// From a GitHub GraphQL `Release` node.
  factory ForgeRelease.fromGhGql(Map<String, dynamic> n) => ForgeRelease(
    tagName: n['tagName'] as String? ?? '',
    name: n['name'] as String? ?? '',
    publishedAt: n['publishedAt'] as String?,
  );

  /// From a GitLab GraphQL `Release` node.
  factory ForgeRelease.fromGlabGql(Map<String, dynamic> n) => ForgeRelease(
    tagName: n['tagName'] as String? ?? '',
    name: n['name'] as String? ?? '',
    publishedAt: n['releasedAt'] as String?,
  );

  /// The publish date as `YYYY-MM-DD`, for compact display.
  String? get publishedDate => _dateOnly(publishedAt);
}

String? _dateOnly(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return iso.split('T').first;
}

/// Combined project overview fetched in one GraphQL round-trip (one SSH
/// round-trip for remote repos).
class ForgeProjectDashboard {
  final List<ForgeIssue> issues;
  final List<ForgeLabel> labels;
  final List<ForgeMilestone> milestones;
  final List<ForgeRelease> releases;

  /// Total counts on the forge, where the API exposes them (see
  /// [graphqlConnectionCount]) — lets the UI say "30 of 974" instead of
  /// silently truncating at the query's `first:` cap. Null = unknown.
  final int? issuesTotal;
  final int? labelsTotal;
  final int? milestonesTotal;
  final int? releasesTotal;

  /// Non-fatal partial-data warning from the fetch (some fields errored while
  /// the rest of the payload was usable). Carried **on the result** because
  /// the service-level `lastGraphqlWarning` field is only valid immediately
  /// after the awaited call — reading it later, at widget-build time, raced
  /// against other GraphQL calls and could surface another repo's warning.
  final String? warning;

  const ForgeProjectDashboard({
    this.issues = const [],
    this.labels = const [],
    this.milestones = const [],
    this.releases = const [],
    this.issuesTotal,
    this.labelsTotal,
    this.milestonesTotal,
    this.releasesTotal,
    this.warning,
  });
}
