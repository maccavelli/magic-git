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
  /// The user-visible issue number: GitHub `number`, GitLab `iid`.
  final int id;
  final String title;

  /// Lowercased wire state (`open`/`closed` on GitHub, `opened`/`closed` on
  /// GitLab); the dashboard only fetches open ones.
  final String state;

  /// Author login/username, when the forge reported one.
  final String? author;
  final List<String> labels;

  const ForgeIssue({
    required this.id,
    required this.title,
    required this.state,
    this.author,
    this.labels = const [],
  });

  /// From a GitHub GraphQL `Issue` node.
  factory ForgeIssue.fromGhGql(Map<String, dynamic> n) {
    final author = n['author'];
    return ForgeIssue(
      id: jsonInt(n['number']),
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'open').toLowerCase(),
      author: author is Map ? author['login'] as String? : null,
      labels: _labelNames(n['labels'], 'name'),
    );
  }

  /// From a GitLab GraphQL `Issue` node. `iid` arrives as a **String**
  /// (`"606072"`) — see [jsonInt].
  factory ForgeIssue.fromGlabGql(Map<String, dynamic> n) {
    final author = n['author'];
    return ForgeIssue(
      id: jsonInt(n['iid']),
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'opened').toLowerCase(),
      author: author is Map ? author['username'] as String? : null,
      labels: _labelNames(n['labels'], 'title'),
    );
  }

  /// The names inside an issue's nested label connection — GitHub calls the
  /// name field `name`, GitLab `title`.
  static List<String> _labelNames(dynamic connection, String field) =>
      graphqlNodes(connection, (l) => l[field] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
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
  /// The user-visible milestone number: GitHub `number`, GitLab `iid`.
  final int id;
  final String title;

  /// Lowercased wire state (`open` on GitHub, `active` on GitLab).
  final String state;

  /// Due date as `YYYY-MM-DD`, when set. GitHub's `dueOn` is a full ISO
  /// timestamp — normalized to the date here so the UI never re-parses;
  /// GitLab's `dueDate` is already date-only.
  final String? due;

  const ForgeMilestone({
    required this.id,
    required this.title,
    required this.state,
    this.due,
  });

  /// From a GitHub GraphQL `Milestone` node.
  factory ForgeMilestone.fromGhGql(Map<String, dynamic> n) => ForgeMilestone(
    id: jsonInt(n['number']),
    title: n['title'] as String? ?? '',
    state: (n['state'] as String? ?? 'open').toLowerCase(),
    due: _dateOnly(n['dueOn'] as String?),
  );

  /// From a GitLab GraphQL `Milestone` node. `iid` arrives as a **String** —
  /// see [jsonInt].
  factory ForgeMilestone.fromGlabGql(Map<String, dynamic> n) => ForgeMilestone(
    id: jsonInt(n['iid']),
    title: n['title'] as String? ?? '',
    state: (n['state'] as String? ?? 'active').toLowerCase(),
    due: _dateOnly(n['dueDate'] as String?),
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
