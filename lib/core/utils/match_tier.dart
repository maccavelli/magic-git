/// The app's one definition of "does this text match what the user typed, and
/// how well?" (MADR 0032 Phase 1).
///
/// Extracted from the command palette's private `_matchTier`, which had the
/// semantics the create sheet's namespace search needs — a typed prefix
/// reaching both an exact group name and a longer one sharing it is tier 1, a
/// plain prefix case. Extracting the function rather than making namespaces
/// into `PaletteEntry`s keeps a create-wizard concern out of
/// `PaletteQueryScope` and `_scopeAllows`, which every future palette entry
/// kind would otherwise have to reason about.
library;

/// Whether [query]'s characters appear in [target] in order, not necessarily
/// adjacent — the loosest match the palette accepts.
bool subsequenceMatch(String query, String target) {
  var queryIndex = 0;
  for (var i = 0; i < target.length && queryIndex < query.length; i++) {
    if (target.codeUnitAt(i) == query.codeUnitAt(queryIndex)) queryIndex++;
  }
  return queryIndex == query.length;
}

/// How well [values] match [query], lower being better, or null for no match.
///
/// Tiers: `0` exact, `1` prefix, `2` substring, `3` subsequence. An empty query
/// matches everything at tier 0, so an unfiltered list keeps its natural order.
/// Comparison is case-insensitive; [values] may be any set of searchable
/// strings for one item (a name, a path, an id) and the best tier across them
/// wins.
int? matchTier(Iterable<String> values, String query) {
  if (query.isEmpty) return 0;
  final needle = query.toLowerCase();
  final haystack = values.map((value) => value.toLowerCase());
  if (haystack.any((value) => value == needle)) return 0;
  if (haystack.any((value) => value.startsWith(needle))) return 1;
  if (haystack.any((value) => value.contains(needle))) return 2;
  if (haystack.any((value) => subsequenceMatch(needle, value))) return 3;
  return null;
}
