/// Translates the History filter's *user intent* into the patterns and
/// pathspecs `git log` actually understands.
///
/// The gap this closes: what a user types in a search box and what `git log`
/// treats a bare string as are not the same language.
///   * `--grep` / `--author` are regexes, not substrings — so `[WIP]` is a
///     syntax error that makes git exit 128, and `hist*view` means "hist,
///     then zero-or-more `t`" rather than the glob the user meant.
///   * `--grep` takes one pattern per flag and ORs them, so a single pattern
///     built by joining words matches only the *contiguous* phrase: typing two
///     words a commit genuinely contains still finds nothing.
///   * a pathspec is rooted at the repo root and case-sensitive, so `file:`
///     with a bare filename or folder name — the thing users actually type —
///     matches nothing at all.
///
/// So user terms are treated as *literal text with glob wildcards* (`*`, `?`),
/// which is what a search box means everywhere else, and this library compiles
/// that to git's languages: ERE for the header/message patterns, `:(icase,glob)`
/// pathspec magic for paths.
library;

/// The ERE metacharacters that must be escaped to match literally. `*` and `?`
/// are deliberately absent — they're the wildcards, handled in [globToRegExp].
const _ereMeta = r'.^$+()[]{}|\';

/// Compiles one user term to an ERE that matches it literally, except for the
/// glob wildcards `*` (any run of characters) and `?` (any single character).
///
/// Escaping everything else is what keeps a subject like `[WIP] fix (again)`
/// searchable: unescaped, its brackets are an unbalanced-bracket error and git
/// exits 128 — which surfaces as the whole History list failing to load, not as
/// "no results".
String globToRegExp(String term) {
  final out = StringBuffer();
  for (final ch in term.split('')) {
    switch (ch) {
      case '*':
        out.write('.*');
      case '?':
        out.write('.');
      default:
        if (_ereMeta.contains(ch)) out.write(r'\');
        out.write(ch);
    }
  }
  return out.toString();
}

/// The `--grep` patterns for a free-text message search — one per whitespace-
/// separated word, to be ANDed by `--all-match`.
///
/// Words are ANDed rather than joined into one pattern because a search box
/// means "commits mentioning all of these", not "commits containing this exact
/// phrase": `patch collapse` must find `feat(patch): add collapse …`, which a
/// single contiguous pattern never does.
List<String> messageGrepPatterns(String? message) {
  final text = message?.trim() ?? '';
  if (text.isEmpty) return const [];
  return [
    for (final word in text.split(RegExp(r'\s+')))
      if (word.isNotEmpty) globToRegExp(word),
  ];
}

/// The `--author` pattern. One pattern, not per-word: an author term is a name
/// or email, and its spaces are part of it (`author:"Mac Smith"`).
String? authorGrepPattern(String? author) {
  final text = author?.trim() ?? '';
  if (text.isEmpty) return null;
  return globToRegExp(text);
}

/// The pathspecs for a `file:` / `path:` term — the set of ways the term could
/// reasonably name what the user meant, ORed together (git ORs pathspecs).
///
/// A raw pathspec is rooted and case-sensitive, so it only ever matches a path
/// spelled out in full from the repo root. Users type a *bare* filename
/// (`history_view.dart`) or folder (`history`), so on top of the rooted reading
/// we also match the term at any depth, as a substring of a filename or of a
/// directory name — which is what "filter by file or folder" is understood to
/// mean.
///
/// A term the user globbed themselves (`*.dart`) is taken at its word: it's
/// matched as written and at any depth, but not substring-widened — the
/// wildcards already say where the fuzziness goes.
List<String> searchPathspecs(String? path) {
  final term = path?.trim() ?? '';
  if (term.isEmpty) return const [];

  if (term.contains('*') || term.contains('?')) {
    return [
      ':(icase,glob)$term',
      // Anchor-free reading of the same glob, so `*.dart` isn't limited to
      // files sitting at the repo root.
      if (!term.startsWith('**/')) ':(icase,glob)**/$term',
    ];
  }

  // A trailing slash is how people write "this folder"; it's noise inside the
  // substring forms below (`lib/core/` → `**/*lib/core/*/**`), so drop it.
  final bare = term.endsWith('/')
      ? term.substring(0, term.length - 1)
      : term;

  return [
    // The literal reading: an exact path from the repo root, or a directory
    // prefix (which git already takes to mean everything under it).
    ':(icase)$term',
    // …a file whose name contains the term, anywhere in the tree.
    ':(icase,glob)**/*$bare*',
    // …or anything inside a directory whose name contains the term.
    ':(icase,glob)**/*$bare*/**',
  ];
}

/// A commit-hash prefix git can actually look up. Git's own object-name
/// disambiguation needs at least 4 hex digits, and anything non-hex is not a
/// hash at all — in both cases there is nothing to resolve, and saying so here
/// keeps the caller from spending a round trip to be told the same thing.
bool isResolvableShaPrefix(String? sha) {
  final text = sha?.trim() ?? '';
  return RegExp(r'^[0-9a-fA-F]{4,40}$').hasMatch(text);
}
