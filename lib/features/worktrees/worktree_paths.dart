/// Path canonicalization for the worktree guards that compare paths.
///
/// These comparisons are load-bearing (don't nest a worktree inside the
/// repository; the picked folder must BE the worktree) and must not be fooled
/// by symlinks: on macOS `/tmp` and `/var` are symlinks into `/private`, so
/// the folder picker returns `/private/tmp/…` while git or the user says
/// `/tmp/…`. The service layer already resolves symlinks
/// (`--path-format=absolute`); these helpers give the UI guards the same
/// footing.
library;

import 'dart:io';

/// [path] with symlinks resolved when it exists on THIS machine; returned
/// unchanged otherwise. Remote-backend paths name directories on the remote
/// host and legitimately don't resolve here — the comparison then degrades to
/// the plain string form it always used.
String canonicalPath(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

/// Canonical form of a path that may not exist yet (a worktree destination).
/// An existing path resolves fully (the leaf itself may be the symlink); a
/// not-yet-created one resolves its parent — which does exist when it came
/// from the folder picker — and re-appends the leaf.
String canonicalDestination(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    final cut = path.lastIndexOf('/');
    if (cut <= 0) return path;
    return '${canonicalPath(path.substring(0, cut))}/${path.substring(cut + 1)}';
  }
}

/// Whether [path] is [repoPath] or nested inside it, symlink-insensitively —
/// the "a worktree inside the repository shows up as untracked noise in its
/// own status" guard used by the Add sheet and Move.
bool isInsideRepo(String path, String repoPath) {
  final dest = canonicalDestination(path);
  final repo = canonicalPath(repoPath);
  return dest == repo || dest.startsWith('$repo/');
}
