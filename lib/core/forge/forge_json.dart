/// JSON plumbing shared by both forge CLI services — `gh` and `glab` speak
/// the same JSON dialect for the parts that matter here, and these helpers
/// were byte-identical twins in the two services before being pulled out.
library;

/// Maps a decoded JSON list through [from]. A `null` decode is an empty
/// result; a non-list (a malformed response) invokes [onMalformed] — the
/// caller throws its own typed exception ([GhException]/[GlabException]), so
/// "no rows" stays distinguishable from "something is broken" and errors keep
/// their forge identity.
List<T> mapJsonList<T>(
  dynamic decoded,
  T Function(Map<String, dynamic>) from, {
  required Never Function(String message) onMalformed,
}) {
  if (decoded == null) return const [];
  if (decoded is! List) {
    onMalformed('expected a JSON array, got ${decoded.runtimeType}');
  }
  return decoded.whereType<Map<String, dynamic>>().map(from).toList();
}

/// Coerces a JSON scalar to an int, or `null` when the value is absent or
/// unparseable. GitLab's GraphQL API returns `iid` fields as **strings**
/// (`"606072"`) while its REST API returns numbers and GitHub's GraphQL
/// returns Int — one tolerant reader instead of per-site casts. (A blind
/// `as num?` cast here crashed the entire GitLab dashboard parse on any real
/// project, because every issue and milestone iid arrives as a String.)
///
/// Returns `null` — not a fabricated `0` — for a missing/garbage id, so an
/// unknown id stays distinguishable from a real one and two unparseable rows
/// don't collide on `0` (which would, e.g., produce duplicate milestone-picker
/// keys). Callers decide how to render/skip an unknown id.
int? jsonIntOrNull(dynamic v) => switch (v) {
  final num n => n.toInt(),
  final String s => int.tryParse(s),
  _ => null,
};

/// Maps a GraphQL connection object's `nodes` list through [from]. Anything
/// that isn't the expected `{nodes: [...]}` shape is an empty result — a
/// missing connection is "no rows", never a crash. Was a byte-identical
/// private helper in both forge services' dashboard parsers.
List<T> graphqlNodes<T>(
  dynamic connection,
  T Function(Map<String, dynamic>) from,
) {
  if (connection is! Map<String, dynamic>) return const [];
  final list = connection['nodes'];
  if (list is! List) return const [];
  return list.whereType<Map<String, dynamic>>().map(from).toList();
}

/// Total size of a GraphQL connection, when the forge exposes one: GitHub
/// calls it `totalCount` (on every connection), GitLab `count` (on issues,
/// labels, and releases — `MilestoneConnection` has neither, verified against
/// gitlab.com). Null means unknown, which is distinct from zero.
int? graphqlConnectionCount(dynamic connection) {
  if (connection is! Map<String, dynamic>) return null;
  final v = connection['totalCount'] ?? connection['count'];
  return v is num ? v.toInt() : null;
}

/// Extracts a joined message from a GraphQL response's `errors` array, or
/// null when there are none. GraphQL reports query failures **in the body
/// with HTTP 200**, so callers must inspect this rather than trusting the
/// HTTP status or the CLI's exit code.
String? joinedGraphqlErrors(Map<String, dynamic> decoded) {
  final errors = decoded['errors'];
  if (errors is! List || errors.isEmpty) return null;
  final joined = errors
      .map((e) => e is Map ? e['message']?.toString() : e?.toString())
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join('; ');
  return joined.isEmpty ? 'unknown GraphQL error' : joined;
}

/// First eight characters of a commit SHA for display (empty for null) —
/// shared by the GitHub and GitLab models, which have no common base type.
String shortShaOf(String? sha) =>
    sha == null ? '' : sha.substring(0, sha.length.clamp(0, 8));
