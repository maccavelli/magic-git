/// Client-side approximation of `git check-ref-format` — shared by every
/// surface that names a ref (create branch, rename branch, create tag), so
/// the common mistakes get a specific message *before* a round trip instead
/// of a raw git error after one. git itself remains the authority (and
/// `--end-of-options` already keeps any name out of argv-option position).
///
/// [kind] only changes the wording ("A tag name…" / "A branch name…") — the
/// rules are identical: both live under `refs/` and share git's ref-format
/// constraints.
///
/// Returns null for an acceptable name — and for the empty string, which
/// callers handle by disabling their submit affordance rather than showing
/// an error for a field the user simply hasn't filled yet.
String? refNameProblem(String name, {String kind = 'branch'}) {
  if (name.isEmpty) return null; // emptiness disables the button silently
  final a = kind == 'branch' ? 'A branch name' : 'A tag name';
  if (name.contains(RegExp(r'\s'))) return 'No spaces in a $kind name.';
  const forbidden = ['~', '^', ':', '?', '*', '[', '\\'];
  for (final ch in forbidden) {
    if (name.contains(ch)) return '$a cannot contain "$ch".';
  }
  if (name.contains('..')) return '$a cannot contain "..".';
  if (name.contains('@{')) return '$a cannot contain "@{".';
  if (name == '@') return '$a cannot be the single character "@".';
  if (name.startsWith('-')) return '$a cannot start with "-".';
  if (name.startsWith('/') || name.endsWith('/') || name.contains('//')) {
    return '$a cannot start or end with "/" (or contain "//").';
  }
  if (name.startsWith('.') || name.endsWith('.')) {
    return '$a cannot start or end with ".".';
  }
  // Component-level rules: every slash-separated part is its own ref
  // component, and git forbids a component starting with "." or ending with
  // ".lock" ("a/.b" and "a.lock/b" both fail check-ref-format).
  for (final part in name.split('/')) {
    if (part.startsWith('.')) {
      return '$a component cannot start with "." ("$part").';
    }
    if (part.endsWith('.lock')) {
      return '$a component cannot end with ".lock" ("$part").';
    }
  }
  if (name.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
    return '$a cannot contain control characters.';
  }
  return null;
}
