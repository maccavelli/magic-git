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
