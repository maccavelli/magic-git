/// POSIX path helpers, canonicalized out of the copies that had accumulated
/// across the app (MADR 0033).
///
/// Before this file, `lib/` carried **13** private path helpers. `_basename`
/// alone existed **eight** times in two behaviourally different families that
/// disagreed on `a/b//`, `/` and `//` — so a doubled slash rendered an empty
/// drag label in one place and the right name in another.
///
/// **These functions are canonicalized on behaviour, not on name.** Two pairs
/// deliberately keep separate contracts, because merging them would break a
/// caller:
///
/// * [stripTrailingSlashes] collapses a bare root to the empty string;
///   [stripTrailingSlashesKeepRoot] preserves it. `HostFsService`'s
///   `removeDirGuarded` depends on the *collapsing* one — the empty result is
///   what makes it refuse to `rm -rf` directly under `/`. Using the
///   root-preserving variant there leaves that guard as dead code while its
///   own test still passes (demonstrated 2026-09-06).
/// * [dirname] is the create/clone sheets' "parent directory of this path",
///   which treats a trailing slash as insignificant. It is **not** the same as
///   `EnvironmentProbe`'s private `_dirname`, which treats a trailing slash
///   literally and maps a bare name to the empty string so it cannot inject a
///   nonsensical `$PATH` entry. That one stays where it is.
library;

/// Last path segment: `/a/b/c` and `/a/b/c/` both give `c`.
///
/// Empty segments are dropped, so any number of trailing or repeated slashes
/// is tolerated, and a path that is nothing but slashes falls back to the
/// input rather than the empty string — a display label should never come
/// back blank for a non-empty path.
String basename(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Parent directory of [path], with trailing slashes treated as
/// insignificant: `/srv/repo` and `/srv/repo/` both give `/srv`.
///
/// Anything whose parent would be the root — or that has no parent at all —
/// gives `/`, never the empty string, so the result is always usable as a
/// directory.
String dirname(String path) {
  final trimmed = stripTrailingSlashes(path);
  final slash = trimmed.lastIndexOf('/');
  if (slash <= 0) return '/';
  return trimmed.substring(0, slash);
}

/// Removes every trailing `/`, **including** from a bare root: `/` gives `''`.
///
/// The empty result for a root path is load-bearing, not an edge case —
/// `HostFsService.removeDirGuarded` tests it to refuse a delete directly under
/// `/`, and `HostFsService.joinPath` relies on it to build `/x` rather than
/// `//x`. Use [stripTrailingSlashesKeepRoot] where a root path must survive.
String stripTrailingSlashes(String path) {
  var end = path.length;
  while (end > 0 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}

/// Removes trailing `/` but keeps a bare root: `/` stays `/`, `//` gives `/`.
///
/// For normalizing a user-supplied directory path, where collapsing `/` to the
/// empty string would turn "the filesystem root" into "no path at all".
String stripTrailingSlashesKeepRoot(String path) {
  var end = path.length;
  while (end > 1 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}
