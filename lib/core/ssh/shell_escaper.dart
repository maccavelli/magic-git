class ShellEscaper {
  /// Escapes a single argument for a POSIX shell so its contents are always a
  /// single literal token — never syntax. This is the sole defence against
  /// command injection, so every caller-influenced value (paths, refs, branch
  /// names, commit messages) must pass through here. The empty string escapes
  /// to `''` naturally.
  ///
  /// The app targets POSIX remotes only (a native Windows port lives in a
  /// separate codebase), so there is no cross-shell branching.
  ///
  /// Rejects an embedded NUL byte, built via `String.fromCharCode(0)` rather
  /// than an escape literal in source (which is fiddly to keep unambiguous):
  /// a C-string-based shell/exec argument vector can't represent a NUL
  /// mid-string, so silently passing one through risks the value being
  /// truncated on the remote side while call sites here still reason about
  /// the full, untruncated Dart string.
  static final String _nulByte = String.fromCharCode(0);

  static String escape(String input) {
    if (input.contains(_nulByte)) {
      throw ArgumentError(
        'cannot shell-escape a string containing a NUL byte',
      );
    }
    return "'${input.replaceAll("'", "'\\''")}'";
  }
}
