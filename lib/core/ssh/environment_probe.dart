import 'package:flutter/foundation.dart';

import '../settings/tool_catalog.dart';
import 'shell_escaper.dart';
import 'ssh_command_executor.dart';

/// The remote host's OS and resolved external-binary locations, discovered once
/// at connect time. Used to (a) augment the exec channel's minimal `$PATH` so
/// user-installed tools (e.g. Homebrew's `/opt/homebrew/bin`) are found, and
/// (b) rewrite each command's binary to its resolved absolute path.
class RemoteEnvironment {
  /// 'macos' | 'linux' | 'unknown'.
  final String os;

  /// Augmented PATH: override dirs, then per-user dirs (`$HOME/.local/bin`,
  /// `$HOME/bin`), then the OS's shared package-manager dirs, then the login
  /// shell's PATH, then the system dirs — so a user's own install always wins
  /// over a system-wide one. Keeping the per-user dirs ahead of
  /// `/usr/local/bin` is load-bearing: a system shim there (e.g. a `glab`/`gh`
  /// wrapper) must not shadow the user's real CLI, or the injected
  /// `!glab auth git-credential` helper resolves to the shim and HTTPS forge
  /// auth dies with "could not read Username".
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

  /// This environment with [versions] merged in (restricted to tools that
  /// actually resolved) — versions arrive from a separate background probe
  /// after connect, not from the connect-time discovery pass.
  RemoteEnvironment withVersions(Map<String, String> versions) =>
      RemoteEnvironment(
        os: os,
        path: path,
        found: found,
        overridden: overridden,
        versions: {
          for (final e in versions.entries)
            if (found.containsKey(e.key)) e.key: e.value,
        },
      );

  /// Human label for the detected OS.
  String get osLabel => switch (os) {
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => 'Unknown',
  };
}

/// Probes the remote host once per connection to discover its OS, an augmented
/// PATH, and the absolute location of each required binary — searching common
/// user paths (per OS) before system paths, and honoring settings overrides.
class EnvironmentResolver {
  final CommandExecutor _executor;
  const EnvironmentResolver(this._executor);

  /// One round trip: detect OS, compute an augmented PATH (per-user dirs, then
  /// shared package dirs and the login shell's PATH, ahead of system dirs), and
  /// `command -v` each binary
  /// under it. [overrides] (binary → absolute path) win over discovery, and
  /// their directories are prepended to the PATH.
  ///
  /// Deliberately does NOT version-check the discovered tools: this call sits
  /// on the connect critical path, and `--version` across the whole catalog
  /// spawns up to seven extra processes — two of which (`gh`, `glab`) run
  /// update checks that can block on the network. Versions come from
  /// [probeVersions], run in the background once the session is already up.
  Future<RemoteEnvironment> resolve(
    String repoPath, {
    Map<String, String> overrides = const {},
  }) async {
    final script = _probeScript;
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
      }
    }
    return _fromParts(os, aug, discovered, const {}, overrides);
  }

  /// Version-checks the given resolved binaries (name → absolute path) in one
  /// round trip, returning name → clean `x.y.z` for every tool whose
  /// `--version` output parsed. Run *after* connect, off the critical path:
  /// this spawns one process per tool, and `gh`/`glab` may otherwise stall on
  /// their update checks — suppressed here (and app-wide via
  /// [CommandFormatter.defaultEnv]) with their no-update-check env vars.
  Future<Map<String, String>> probeVersions(
    Map<String, String> binaries, {
    String repoPath = '.',
  }) async {
    if (binaries.isEmpty) return const {};
    final script = StringBuffer(
      // Belt-and-braces with defaultEnv: never let a version banner become a
      // network wait, even for an executor that doesn't carry defaultEnv.
      'export GH_NO_UPDATE_NOTIFIER=1 GLAB_CHECK_UPDATE=false; ',
    );
    binaries.forEach((name, path) {
      // Names come from the fixed probe catalog (shell-safe by construction);
      // paths are discovered/user-supplied and must be escaped.
      script.write(
        'v=\$(${ShellEscaper.escape(path)} --version 2>&1 | head -n1 || true); '
        'echo "VER=$name=\$v"; ',
      );
    });
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script.toString()],
      timeout: const Duration(seconds: 20),
      lane: ExecLane.read,
    );
    if (!result.isSuccess) return const {};
    final versions = <String, String>{};
    for (final line in result.stdout.split('\n')) {
      if (!line.startsWith('VER=')) continue;
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
    return versions;
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

  /// Directory entries from a login shell's `$PATH` output, discarding
  /// anything that is not plausibly a directory.
  ///
  /// A login shell is a hostile source: `.zshrc` files print banners, MOTDs,
  /// version-manager chatter and warnings, and all of it lands on the same
  /// stdout as the value. Feeding that through unvalidated appends junk to a
  /// PATH whose *ordering is load-bearing* — the resolved `glab` must not be a
  /// shim. So an entry has to be absolute and single-line to count, and the
  /// list is capped: a real PATH is tens of entries, not thousands.
  @visibleForTesting
  static List<String> parseLoginShellPath(
    String stdout, {
    int maxEntries = 64,
  }) {
    final out = <String>[];
    for (final raw in stdout.split(':')) {
      final d = raw.trim();
      if (d.length < 2 || !d.startsWith('/')) continue;
      if (d.contains('\n') || d.contains('\r') || d.contains('=')) continue;
      out.add(d);
      if (out.length >= maxEntries) break;
    }
    return out;
  }

  /// [current] with any [additional] directories it lacks appended, preserving
  /// [current]'s order and dropping blanks and duplicates.
  ///
  /// Appended, never prepended. The per-user-before-system ordering is
  /// load-bearing: a system shim in `/usr/local/bin` that shadows the user's
  /// real `glab` breaks the injected `!glab auth git-credential` helper and
  /// HTTPS forge auth dies with "could not read Username". A login shell that
  /// wants to *reorder* the PATH does not get to.
  static String mergeLoginShellPath(String current, List<String> additional) {
    final seen = <String>{};
    final out = <String>[];
    for (final d in current.split(':')) {
      final t = d.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    for (final d in additional) {
      final t = d.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    return out.join(':');
  }

  /// The login shell's own `$PATH`, split into directories.
  ///
  /// Runs AFTER connect, off the critical path — see [_probeScript]. Entirely
  /// best-effort: any failure, and any shell that hangs past the timeout,
  /// yields an empty list and the session carries on with the augmented PATH
  /// it already has.
  Future<List<String>> probeLoginShellPath({String repoPath = '.'}) async {
    try {
      final result = await _executor.execute(
        repoPath: repoPath,
        gitArgs: [
          'sh',
          '-c',
          // No temp file and no busy-wait: the command's own timeout is the
          // bound, and a shell that never returns simply loses.
          r"""${SHELL:-sh} -lc 'printf %s "$PATH"' 2>/dev/null || true""",
        ],
        timeout: const Duration(seconds: 5),
        lane: ExecLane.read,
      );
      if (!result.isSuccess) return const [];
      return parseLoginShellPath(result.stdout);
    } on Object {
      return const [];
    }
  }

  /// The connect-time probe script — exposed so tests can pin its contract:
  /// pure lookups, nothing spawned.
  @visibleForTesting
  static String get probeScriptForTest => _probeScript;

  // POSIX sh probe. Emits `OS=`, `PATH=` (augmented), and `BIN=<name>=<path>`
  // lines. Per-user dirs, then the OS's shared package dirs and the login
  // shell's PATH, come before system dirs, so `command -v` resolves a user's
  // own install ahead of a system-wide one. Pure lookups
  // only — no tool is actually spawned (see [probeVersions] for the deferred
  // `--version` pass), keeping this connect-blocking round trip as close to
  // shell-builtin speed as the login-shell PATH capture allows.
  //
  // The binary list is generated from [kProbedBinaries] — the catalog plus its
  // capabilities — rather than written out here. A hand-written list is how a
  // tool ends up overridable in Settings but never actually looked for on the
  // host (or looked for, and missing from the doctor panel).
  // The login shell's PATH is NOT captured here. It used to be, by
  // backgrounding `$SHELL -lc` and busy-waiting up to 3s for it in 30 forked
  // `sleep 0.1`s — on the connect critical path, before `connected` is
  // published, and re-paid on each of up to 20 auto-reconnect attempts. The
  // payoff is a `brew shellenv` line in someone's zshrc, and the per-OS `c`
  // list below already covers exactly that in the common case. It now happens
  // after connect instead (see [probeLoginShellPath]), which also removes the
  // guessable `$TMPDIR/mg_lp.$$` the capture wrote through a plain `>`
  // redirect (0024 P1/M4).
  static final String _probeScript =
      'os=\$(uname -s 2>/dev/null || echo unknown); '
      // Per-user dirs (`u`) come before the OS's shared package-manager dirs
      // (`c`) so the user's own install always wins — a system shim in
      // /usr/local/bin must never shadow ~/.local/bin (it would break the
      // injected forge credential helper; see [RemoteEnvironment.path]).
      'u="\$HOME/.local/bin:\$HOME/bin"; '
      'case "\$os" in '
      'Darwin) c="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin" ;; '
      'Linux) c="/usr/local/bin:/usr/local/sbin:/home/linuxbrew/.linuxbrew/bin:/snap/bin" ;; '
      '*) c="/usr/local/bin" ;; '
      'esac; '
      'aug="\$u:\$c:\$PATH:/usr/bin:/bin:/usr/sbin:/sbin"; '
      'echo "OS=\$os"; '
      'echo "PATH=\$aug"; '
      // Bare names, unquoted, in a `for` list: safe because every entry is a
      // catalog binary name (a plain identifier), never user input.
      'for b in ${kProbedBinaries.join(' ')}; do '
      'p=\$(PATH="\$aug" command -v "\$b" 2>/dev/null || true); '
      'echo "BIN=\$b=\$p"; '
      'done';
}
