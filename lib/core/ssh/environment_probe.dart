import 'ssh_command_executor.dart';

/// The remote host's OS and resolved external-binary locations, discovered once
/// at connect time. Used to (a) augment the exec channel's minimal `$PATH` so
/// user-installed tools (e.g. Homebrew's `/opt/homebrew/bin`) are found, and
/// (b) rewrite each command's binary to its resolved absolute path.
class RemoteEnvironment {
  /// 'macos' | 'linux' | 'unknown'.
  final String os;

  /// Augmented PATH: override dirs and common user dirs first, then the login
  /// shell's PATH, then the system dirs — so user installs win over system ones.
  final String path;

  /// Binary name → absolute path, for every required tool that resolved
  /// (settings overrides merged over auto-discovery). Missing keys weren't
  /// found. Used to rewrite `argv[0]`.
  final Map<String, String> found;

  /// The subset of [found] supplied by a settings override rather than
  /// discovery (for display in Settings).
  final Set<String> overridden;

  /// Binary name → detected version as a clean `x.y.z` string, for every tool
  /// whose `--version` output parsed. Absent when the tool wasn't found, or was
  /// found but printed nothing version-shaped (e.g. some inotifywait builds).
  final Map<String, String> versions;

  const RemoteEnvironment({
    required this.os,
    required this.path,
    required this.found,
    this.overridden = const {},
    this.versions = const {},
  });

  static const RemoteEnvironment empty = RemoteEnvironment(
    os: 'unknown',
    path: '',
    found: {},
  );

  bool has(String bin) => found.containsKey(bin);
  String? pathOf(String bin) => found[bin];

  /// Detected `x.y.z` version for [bin], or null if unknown.
  String? versionOf(String bin) => versions[bin];

  /// Human label for the detected OS.
  String get osLabel => switch (os) {
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => 'Unknown',
  };
}

/// The external binaries Magic Git depends on and lets the user override.
const List<String> kOverridableBinaries = [
  'git',
  'glab',
  'gh',
  'fswatch',
  'inotifywait',
];

/// Probes the remote host once per connection to discover its OS, an augmented
/// PATH, and the absolute location of each required binary — searching common
/// user paths (per OS) before system paths, and honoring settings overrides.
class EnvironmentResolver {
  final CommandExecutor _executor;
  const EnvironmentResolver(this._executor);

  /// One round trip: detect OS, compute an augmented PATH (common user dirs and
  /// the login shell's PATH ahead of system dirs), and `command -v` each binary
  /// under it. [overrides] (binary → absolute path) win over discovery, and
  /// their directories are prepended to the PATH.
  Future<RemoteEnvironment> resolve(
    String repoPath, {
    Map<String, String> overrides = const {},
  }) async {
    const script = _probeScript;
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      timeout: const Duration(seconds: 20),
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      // Probe failed (e.g. odd shell) — fall back to overrides only so the user
      // can still point at the binaries manually.
      return _fromParts('unknown', '', const {}, const {}, overrides);
    }

    var os = 'unknown';
    var aug = '';
    final discovered = <String, String>{};
    final versions = <String, String>{};
    for (final line in result.stdout.split('\n')) {
      if (line.startsWith('OS=')) {
        final raw = line.substring(3).trim();
        os = switch (raw) {
          'Darwin' => 'macos',
          'Linux' => 'linux',
          _ => 'unknown',
        };
      } else if (line.startsWith('PATH=')) {
        aug = line.substring(5).trim();
      } else if (line.startsWith('BIN=')) {
        final rest = line.substring(4);
        final eq = rest.indexOf('=');
        if (eq > 0) {
          final name = rest.substring(0, eq);
          final p = rest.substring(eq + 1).trim();
          if (p.isNotEmpty) discovered[name] = p;
        }
      } else if (line.startsWith('VER=')) {
        // VER=<name>=<raw first line of `<bin> --version`>. Extract a clean
        // x.y.z; skip anything without a version-shaped token.
        final rest = line.substring(4);
        final eq = rest.indexOf('=');
        if (eq > 0) {
          final name = rest.substring(0, eq);
          final v = _parseVersion(rest.substring(eq + 1));
          if (v != null) versions[name] = v;
        }
      }
    }
    return _fromParts(os, aug, discovered, versions, overrides);
  }

  /// Pulls the first `X.Y[.Z]` token out of arbitrary `--version` output and
  /// normalizes it to `X.Y.Z` (missing patch → 0). Returns null if none.
  static String? _parseVersion(String raw) {
    final m = _versionPattern.firstMatch(raw);
    if (m == null) return null;
    final patch = m.group(3) ?? '0';
    return '${m.group(1)}.${m.group(2)}.$patch';
  }

  static final RegExp _versionPattern = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

  RemoteEnvironment _fromParts(
    String os,
    String aug,
    Map<String, String> discovered,
    Map<String, String> versions,
    Map<String, String> overrides,
  ) {
    // Clean overrides (drop blanks) and merge over discovery — overrides win.
    final ov = <String, String>{
      for (final e in overrides.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
    final found = <String, String>{...discovered, ...ov};

    // Prepend each override's directory to the PATH so in-script tools honor
    // it. If the probe itself failed, `aug` is empty — fall back to a bare
    // system PATH rather than exporting *only* the override directories,
    // which would leave `sh`/`cat`/`ls`/`sed`/`mktemp`/`rm` (every bare-name
    // command this app shells out to besides `git`/`glab`) unresolvable.
    final dirs = <String>[
      for (final p in ov.values) _dirname(p),
      ...(aug.isEmpty ? _fallbackSystemPath : aug).split(':'),
    ];
    final seen = <String>{};
    final path = [
      for (final d in dirs)
        if (d.isNotEmpty && seen.add(d)) d,
    ].join(':');

    return RemoteEnvironment(
      os: os,
      path: path,
      found: found,
      overridden: ov.keys.toSet(),
      // Only report versions for tools we actually resolved (an override may
      // point somewhere the probe didn't version-check).
      versions: {
        for (final e in versions.entries)
          if (found.containsKey(e.key)) e.key: e.value,
      },
    );
  }

  /// Baseline PATH assumed to exist on essentially any POSIX host, used only
  /// when the probe script itself failed to run (so there's no augmented PATH
  /// to build on).
  static const String _fallbackSystemPath = '/usr/bin:/bin:/usr/sbin:/sbin';

  static String _dirname(String p) {
    final i = p.lastIndexOf('/');
    // No slash at all (a bare name like "git") has no directory component —
    // returning the input unchanged would otherwise inject a nonsensical
    // literal-name PATH entry. Callers filter empty entries out. A slash at
    // index 0 (e.g. "/git") means the parent is root, not "" (which a plain
    // `substring(0, 0)` would produce).
    if (i < 0) return '';
    if (i == 0) return '/';
    return p.substring(0, i);
  }

  // POSIX sh probe. Emits `OS=`, `PATH=` (augmented), `BIN=<name>=<path>`, and
  // (for each found tool) `VER=<name>=<first line of `<bin> --version`>` lines.
  // Common user dirs and the login shell's PATH come before system dirs, so
  // `command -v` resolves user-installed tools first. Versions are only queried
  // for tools that resolved, so a missing binary is never spawned (which would
  // just 127) — the `--version` call is `2>&1` because some tools (notably
  // inotifywait) print their banner to stderr.
  static const String _probeScript =
      'os=\$(uname -s 2>/dev/null || echo unknown); '
      // Prefer the user's login shell (sources their profile, e.g. Homebrew's
      // `brew shellenv`), falling back to sh.
      'lp=\$(\${SHELL:-sh} -lc \'printf %s "\$PATH"\' 2>/dev/null); '
      'case "\$os" in '
      'Darwin) c="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:\$HOME/.local/bin:\$HOME/bin" ;; '
      'Linux) c="/usr/local/bin:/usr/local/sbin:\$HOME/.local/bin:\$HOME/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin" ;; '
      '*) c="/usr/local/bin:\$HOME/.local/bin:\$HOME/bin" ;; '
      'esac; '
      'aug="\$c:\$lp:\$PATH:/usr/bin:/bin:/usr/sbin:/sbin"; '
      'echo "OS=\$os"; '
      'echo "PATH=\$aug"; '
      // `gzip` isn't user-overridable — it's probed so the executor knows it
      // may compress large reads on the wire (see CommandFormatter's
      // compressOutput); a host without it just runs uncompressed.
      'for b in git glab gh fswatch inotifywait stdbuf gzip; do '
      'p=\$(PATH="\$aug" command -v "\$b" 2>/dev/null || true); '
      'echo "BIN=\$b=\$p"; '
      'if [ -n "\$p" ]; then '
      'v=\$(PATH="\$aug" "\$b" --version 2>&1 | head -n1 || true); '
      'echo "VER=\$b=\$v"; '
      'fi; '
      'done';
}
