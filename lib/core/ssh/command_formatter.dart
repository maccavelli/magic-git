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
  };

  /// Both forge CLIs treat these env vars as taking precedence over their own
  /// stored credentials: `glab` reads `GITLAB_TOKEN`/`GITLAB_ACCESS_TOKEN`/
  /// `OAUTH_TOKEN`, and `gh` reads `GH_TOKEN`/`GITHUB_TOKEN` (github.com) plus
  /// `GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN` (Enterprise). Unset (not
  /// just left unexported) before every command — git, glab, and gh alike — so
  /// that if the remote shell's login profile or PAM environment ever ambiently
  /// sets one of these, a forge call doesn't silently authenticate as a
  /// different identity with no error (the exit code stays 0 either way).
  /// Harmless for plain git commands, which never read these vars.
  static const String _unsetAmbientForgeTokens =
      'unset GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN '
      'GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; ';

  /// The same ambient forge-auth vars as [_unsetAmbientForgeTokens], expressed
  /// as an environment map with empty values — for the local backend, which
  /// sets process environment directly via `Process.start` (no shell, so no
  /// `unset` prelude to emit). Both CLIs treat an empty value identically to
  /// unset, so this reproduces the SSH path's guarantee: a `GITLAB_TOKEN` /
  /// `GH_TOKEN` (etc.) in the launching shell's environment can't silently
  /// override the stored `glab auth` / `gh auth` credential. Harmless for plain
  /// git, which never reads these.
  static const Map<String, String> neutralizedForgeTokens = {
    'GITLAB_TOKEN': '',
    'GITLAB_ACCESS_TOKEN': '',
    'OAUTH_TOKEN': '',
    'GH_TOKEN': '',
    'GITHUB_TOKEN': '',
    'GH_ENTERPRISE_TOKEN': '',
    'GITHUB_ENTERPRISE_TOKEN': '',
  };

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
  static String format({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String> env = defaultEnv,
    Map<String, String> binaryPaths = const {},
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
              throw ArgumentError.value(
                e.key,
                'env',
                'invalid environment variable name',
              );
            }
            return '${e.key}=${ShellEscaper.escape(e.value)}';
          }).join(' ')}; ';
    return '$_unsetAmbientForgeTokens$prelude$cd && exec $escapedArgs';
  }
}
