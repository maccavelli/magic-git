import 'shell_escaper.dart';

class CommandFormatter {
  /// A POSIX-portable environment variable name: a letter or underscore
  /// followed by letters, digits, or underscores. Env *values* are shell-
  /// escaped, but keys are interpolated raw into the `export` prelude, so a key
  /// carrying shell metacharacters would break out of its token — validated
  /// here as defense in depth (no current caller passes attacker-controlled
  /// keys).
  static final RegExp _validEnvKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Default environment prelude applied to every command. Disables interactive
  /// prompts/editor and optional index locks.
  static const Map<String, String> defaultEnv = {
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_EDITOR': 'true',
    // Disable *optional* locks (e.g. the opportunistic index refresh a plain
    // `git status` performs). A background/polling read must never take
    // `.git/index.lock`, or it can make the user's concurrent foreground
    // `git add`/`commit` fail spuriously. Only optional sub-operations are
    // skipped; required locks for real writes (commit, checkout) still work.
    'GIT_OPTIONAL_LOCKS': '0',
    // Error classification (GitException.branchNotFullyMerged and friends)
    // matches English substrings of git's gettext-localized stderr. A remote
    // host with a non-English LANG would defeat every such match and dead-end
    // the UI's escalation flows on a raw message. LC_MESSAGES (not LC_ALL)
    // pins message language only, leaving LC_CTYPE — and with it non-ASCII
    // path handling — untouched.
    'LC_MESSAGES': 'C',
    // gh/glab periodically phone home to check for a newer release when
    // invoked. That check is a hidden network round trip from the host that
    // can stall any forge call (including a bare `--version`) on slow or
    // firewalled egress — and its "new version available" banner would only
    // pollute parsed output anyway. Harmless for plain git, which reads
    // neither var.
    'GH_NO_UPDATE_NOTIFIER': '1',
    'GLAB_CHECK_UPDATE': 'false',
  };

  /// Ambient env vars `glab` treats as higher-precedence than its own stored
  /// `glab auth` credential.
  static const List<String> gitlabTokenVars = [
    'GITLAB_TOKEN',
    'GITLAB_ACCESS_TOKEN',
    'OAUTH_TOKEN',
  ];

  /// Ambient env vars `gh` treats as higher-precedence than its own stored
  /// `gh auth` credential — github.com (`GH_TOKEN`/`GITHUB_TOKEN`) and
  /// Enterprise (`GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN`).
  static const List<String> githubTokenVars = [
    'GH_TOKEN',
    'GITHUB_TOKEN',
    'GH_ENTERPRISE_TOKEN',
    'GITHUB_ENTERPRISE_TOKEN',
  ];

  /// Compiles an environment prelude, directory switch, and invocation into a
  /// single injection-safe POSIX command string.
  ///
  /// [gitArgs] is the full argument vector, e.g. `['git', 'commit', '-m', msg]`.
  /// Every element — plus [repoPath] and every environment value — is escaped
  /// individually via [ShellEscaper], so no caller-supplied value (branch name,
  /// ref, file path, commit message) can break out of its token and inject
  /// additional shell commands.
  /// [binaryPaths] maps a bare tool name to its resolved absolute path (from
  /// discovery/settings overrides); when `gitArgs.first` matches, it's rewritten
  /// so the exact binary is used regardless of `$PATH` ordering. A resolved
  /// `PATH` should additionally be supplied in [env] so tools invoked *inside* a
  /// `sh -c` wrapper (e.g. `inotifywait`, `stdbuf`) resolve too.
  ///
  /// The invocation itself runs via `exec`, so the remote shell process
  /// launched for this command *becomes* the git/glab process rather than
  /// forking a child. Without this, a signal sent to the SSH channel (e.g. on
  /// a client-side timeout) is delivered to the shell wrapper, which isn't
  /// guaranteed to forward it to the actual command — a killed shell can leave
  /// the real process running remotely, still holding `.git/index.lock`. With
  /// `exec`, there is no wrapper left to leak: the signal reaches the real
  /// process directly.
  /// [neutralizeEnv] names ambient env vars to `unset` before the command runs
  /// (a forge's token vars, when this connection supplied that forge's token —
  /// see [gitlabTokenVars]/[githubTokenVars] and ConnectionController). Empty
  /// means no `unset` prelude, leaving the remote's own CLI auth untouched.
  ///
  /// [compressOutput] pipes the command's stdout through `gzip -c -1` on the
  /// remote, prefixed by an in-band exit trailer (see [exitTrailerMarker]):
  /// SSH offers no transport compression with this client library
  /// (dartssh2 negotiates `none`), and git's text output (diffs, logs, status)
  /// typically compresses 5-10× — a large win on slow links. The wrapping
  /// costs the `exec` (a shell must survive the command to emit the trailer
  /// and feed the pipe), which is acceptable for the *read-only* commands this
  /// is used with: a read left briefly running after a client-side timeout
  /// dies on SIGPIPE/channel close and holds no locks. The pipeline's own exit
  /// code is gzip's, so the real command's `$?` travels inside the compressed
  /// stream as `\x01EXIT=<n>\x01`, appended after stdout — the executor
  /// recovers it with [SSHCommandExecutor.splitExitTrailer]. stderr is left
  /// uncompressed on its own channel stream.
  ///
  /// When [binaryPaths] contains `gzip`, that absolute path is used for the
  /// pipe (settings overrides and discovery both land there). Bare `gzip`
  /// only appears as a fallback if compression is requested without a resolved
  /// path — callers that gate on discovery should always supply one.
  static String format({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String> env = defaultEnv,
    Map<String, String> binaryPaths = const {},
    Iterable<String> neutralizeEnv = const [],
    bool compressOutput = false,
  }) {
    final args = gitArgs.isNotEmpty && binaryPaths.containsKey(gitArgs.first)
        ? [binaryPaths[gitArgs.first]!, ...gitArgs.skip(1)]
        : gitArgs;
    final escapedArgs = args.map(ShellEscaper.escape).join(' ');
    final cd = 'cd ${ShellEscaper.escape(repoPath)}';
    final prelude = env.isEmpty
        ? ''
        : 'export ${env.entries.map((e) {
            if (!_validEnvKey.hasMatch(e.key)) {
              throw ArgumentError.value(e.key, 'env', 'invalid environment variable name');
            }
            return '${e.key}=${ShellEscaper.escape(e.value)}';
          }).join(' ')}; ';
    // Same validation as env keys above: unset names are interpolated raw
    // into the shell string, so they get the same defense-in-depth gate (only
    // the token-var constants are passed today).
    final unset = neutralizeEnv.isEmpty
        ? ''
        : 'unset ${neutralizeEnv.map((name) {
            if (!_validEnvKey.hasMatch(name)) {
              throw ArgumentError.value(name, 'neutralizeEnv', 'invalid environment variable name');
            }
            return name;
          }).join(' ')}; ';
    if (!compressOutput) {
      return '$unset$prelude$cd && exec $escapedArgs';
    }
    // Prefer the resolved absolute gzip (settings override / discovery);
    // fall back to bare name only if somehow compress was requested without
    // one. Escaped so a path with spaces never breaks the pipe token.
    final gzipBin = ShellEscaper.escape(binaryPaths['gzip'] ?? 'gzip');
    // POSIX group so the trailer's `$?` is the command's own exit, then one
    // pipe through gzip. `printf '\001…'` — POSIX printf interprets octal
    // escapes in its format string, emitting the raw 0x01 marker bytes.
    return "$unset$prelude$cd && "
        "{ $escapedArgs; printf '\\001EXIT=%d\\001' \"\$?\"; } | $gzipBin -c -1";
  }
}
