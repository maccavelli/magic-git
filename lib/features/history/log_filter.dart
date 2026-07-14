/// The History filter field's little query language: free text narrows by
/// commit message, and `key:value` terms narrow by author, file, SHA, or date
/// — e.g. `rename author:mac file:lib/core/ after:2026-01-01`.
///
/// This library only *parses*; every term is then applied by git itself, so a
/// result set is complete rather than "whatever was already loaded". What each
/// term means to git — literal text with `*`/`?` wildcards, matched
/// case-insensitively, paths at any depth — is [log_search]'s job.
library;

/// The parsed filter. Fields are null when the term wasn't given; a
/// null-everywhere filter ([isEmpty]) narrows nothing.
class LogFilter {
  /// Free text — the words that carried no recognized `key:` prefix.
  final String? message;
  final String? author;
  final String? path;

  /// A full or partial commit hash, resolved against the object database — so
  /// it finds the commit wherever it is, not only among the loaded rows.
  final String? sha;

  /// Git date expressions, passed through verbatim: git accepts both
  /// `2026-01-31` and phrases like `2 weeks ago`.
  final String? since;
  final String? until;

  const LogFilter({
    this.message,
    this.author,
    this.path,
    this.sha,
    this.since,
    this.until,
  });

  static const empty = LogFilter();

  bool get isEmpty =>
      message == null &&
      author == null &&
      path == null &&
      sha == null &&
      since == null &&
      until == null;

  @override
  bool operator ==(Object other) =>
      other is LogFilter &&
      other.message == message &&
      other.author == author &&
      other.path == path &&
      other.sha == sha &&
      other.since == since &&
      other.until == until;

  @override
  int get hashCode => Object.hash(message, author, path, sha, since, until);

  @override
  String toString() =>
      'LogFilter(message: $message, author: $author, path: $path, '
      'sha: $sha, since: $since, until: $until)';
}

/// The recognized prefixes, each mapped to the field it fills. Aliases exist
/// where two names are equally natural (`file:`/`path:`, `after:`/`since:`).
///
/// Deliberately a closed set: an *unrecognized* `word:` term is NOT a
/// malformed filter, it's ordinary message text — conventional-commit
/// subjects are full of it (`feat: …`, `fix: …`), and typing `fix: history`
/// must search for the literal text, not silently filter on a `fix` key.
const _keys = <String, _Field>{
  'author': _Field.author,
  'file': _Field.path,
  'path': _Field.path,
  'sha': _Field.sha,
  'commit': _Field.sha,
  'after': _Field.since,
  'since': _Field.since,
  'before': _Field.until,
  'until': _Field.until,
};

enum _Field { author, path, sha, since, until }

/// Parses the filter field. Values may be quoted to include spaces
/// (`author:"Mac Smith"`); a repeated key keeps the last occurrence.
///
/// A space after the colon is honored: `author: samuel` means exactly what
/// `author:samuel` does, with the next token bound as the value. People type
/// the spaced form constantly — it is how the phrase is written in prose —
/// and the previous grammar silently demoted it to *message text*, so the
/// search looked applied and found nothing. A recognized key with no value at
/// the very end of the input (`author:` mid-typing) narrows nothing at all:
/// it is dropped rather than searched for literally, so the list holds still
/// on the way to a real value.
LogFilter parseLogFilter(String input) {
  if (input.trim().isEmpty) return LogFilter.empty;

  final words = <String>[];
  final values = <_Field, String>{};

  final tokens = _tokenize(input);
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final colon = token.indexOf(':');
    if (colon > 0) {
      final field = _keys[token.substring(0, colon).toLowerCase()];
      final value = token.substring(colon + 1).trim();
      if (field != null && value.isNotEmpty) {
        values[field] = value;
        continue;
      }
      if (field != null) {
        // `author: samuel` — the value landed in the next token. Bind it,
        // unless it reads as a key:value term itself (`author: file:x` —
        // taking `file:x` as an author would eat a real term).
        final next = i + 1 < tokens.length ? tokens[i + 1] : null;
        final nextColon = next?.indexOf(':') ?? -1;
        final nextIsTerm =
            nextColon > 0 &&
            _keys.containsKey(next!.substring(0, nextColon).toLowerCase());
        if (next != null && !nextIsTerm) {
          values[field] = next;
          i++;
          continue;
        }
        // Trailing (or key-followed) valueless key: still being typed.
        continue;
      }
    }
    // Bare word or unknown key — ordinary message text (`fix: history` must
    // search for the literal text, not silently filter on a `fix` key).
    words.add(token);
  }

  final message = words.join(' ').trim();
  return LogFilter(
    message: message.isEmpty ? null : message,
    author: values[_Field.author],
    path: values[_Field.path],
    sha: values[_Field.sha],
    since: values[_Field.since],
    until: values[_Field.until],
  );
}

/// Splits on whitespace, honoring quotes so a quoted value stays one token.
/// Quotes are structural, never literal: `author:"Mac Smith"` yields the
/// single token `author:Mac Smith`.
List<String> _tokenize(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quote;

  void flush() {
    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
      buffer.clear();
    }
  }

  for (final ch in input.split('')) {
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        buffer.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == ' ' || ch == '\t') {
      flush();
    } else {
      buffer.write(ch);
    }
  }
  flush();
  return tokens;
}
