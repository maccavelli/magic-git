/// A leading `~` in a repository path, expanded against the host's `$HOME`.
///
/// Every remote command reaches its repository as `cd '<path>'`, and a `~`
/// inside quotes is never expanded, so a path typed as `~/src/repo` failed on
/// every host with "not a git repository" — and, saved on a connection, broke
/// every later connect's watcher sweep. The connect resolves `$HOME` once and
/// expands the paths before any command uses them, so the rest of the app
/// only ever sees absolute paths.
///
/// Only `~` and `~/…` are expanded. `~user/…` names another account's home,
/// which this app has no business guessing; it is left as typed and fails
/// with the host's own message.
library;

/// Whether [path] starts with the current user's home, `~` or `~/`.
bool hasHomePrefix(String path) => path == '~' || path.startsWith('~/');

/// [path] with a leading `~` or `~/` replaced by [home]; any other path
/// unchanged.
String expandHomePath(String path, String home) {
  if (!hasHomePrefix(path)) return path;
  // Without its trailing slash; a home of `/` becomes empty here, so that
  // `~/repo` is `/repo`, not `//repo`.
  final base = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
  if (path == '~') return base.isEmpty ? '/' : base;
  return '$base${path.substring(1)}';
}

/// The host did not report an absolute `$HOME`, so a `~` path cannot be
/// resolved.
class HomePathUnresolved implements Exception {
  const HomePathUnresolved(this.detail);

  final String detail;

  @override
  String toString() =>
      'Could not resolve "~" on the host: its \$HOME was not reported '
      '($detail). Use an absolute repository path.';
}
