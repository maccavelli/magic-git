/// The external command-line tools Magic Git depends on, what each is for, the
/// minimum version we rely on, and how to install it per platform. This is the
/// single source of truth behind environment detection (which binaries the
/// connect-time probe looks for, and their min-version checks), the set of
/// binaries the user may point somewhere else, and the Environment health /
/// "doctor" panel. Adding a tool is a one-line [kToolCatalog] edit — the probe
/// script, the settings overrides and the doctor all derive from it.
///
/// Deliberately dependency-free: [EnvironmentResolver] imports *this* to build
/// its probe, so anything here that reached back for a `RemoteEnvironment`
/// would be a cycle. Interpreting a probe result against the catalog lives one
/// layer up, in `tool_health.dart`.
library;

/// A parsed `major.minor.patch` version, for comparing a detected tool version
/// against a minimum. Tolerant: a missing minor/patch is treated as 0, and any
/// trailing build metadata (e.g. "2.39.3 (Apple Git-145)") is ignored by the
/// caller before parsing.
class ToolVersion implements Comparable<ToolVersion> {
  final int major;
  final int minor;
  final int patch;
  const ToolVersion(this.major, [this.minor = 0, this.patch = 0]);

  static final RegExp _semver = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

  /// Extracts the first `X.Y[.Z]` token from arbitrary version output, e.g.
  /// "git version 2.39.3 (Apple Git-145)" → 2.39.3, "glab 1.40.0" → 1.40.0.
  /// Returns null if no version-looking token is present.
  static ToolVersion? parse(String raw) {
    final m = _semver.firstMatch(raw);
    if (m == null) return null;
    return ToolVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      m.group(3) == null ? 0 : int.parse(m.group(3)!),
    );
  }

  @override
  int compareTo(ToolVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(ToolVersion other) => compareTo(other) < 0;
  bool operator >=(ToolVersion other) => compareTo(other) >= 0;

  String get display => '$major.$minor.$patch';

  @override
  String toString() => display;

  @override
  bool operator ==(Object other) =>
      other is ToolVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

/// How important a tool is — drives whether a missing tool blocks, warns, or is
/// merely informational.
enum ToolTier {
  /// The app can't function for this connection without it (git).
  essential,

  /// Gates a whole feature area but core git still works (glab → GitLab,
  /// gh → GitHub).
  feature,

  /// Nice to have; the app degrades gracefully (fswatch/inotifywait →
  /// live refresh, which falls back to periodic polling when absent).
  optional,
}

extension ToolTierLabel on ToolTier {
  String get label => switch (this) {
    ToolTier.essential => 'Required',
    ToolTier.feature => 'Feature',
    ToolTier.optional => 'Optional',
  };
}

/// One installable tool, its purpose, minimum supported version, and OS
/// relevance.
class ToolSpec {
  final String bin;
  final ToolTier tier;

  /// One-line description of what the app uses it for.
  final String purpose;

  /// Minimum version the app relies on, or null if any version is acceptable.
  final ToolVersion? minVersion;

  /// Restricts relevance to a single OS ('macos' | 'linux'); null = all. The
  /// file watchers are the only OS-specific tools: fswatch on macOS,
  /// inotifywait on Linux.
  final String? onlyOs;

  /// Documentation / install landing page.
  final String docsUrl;

  const ToolSpec({
    required this.bin,
    required this.tier,
    required this.purpose,
    this.minVersion,
    this.onlyOs,
    required this.docsUrl,
  });

  /// Whether this tool is relevant on [os] ('macos' | 'linux' | 'unknown').
  /// When the OS isn't yet known (disconnected), everything is relevant so the
  /// panel can still describe the full toolset.
  bool relevantOn(String os) =>
      onlyOs == null || os == 'unknown' || onlyOs == os;
}

/// The tools Magic Git shells out to. Order is display order in the doctor
/// panel: most critical first.
const List<ToolSpec> kToolCatalog = [
  ToolSpec(
    bin: 'git',
    tier: ToolTier.essential,
    purpose:
        'Every repository operation — status, diff, commit, history, sync.',
    // The app uses `--end-of-options` throughout, added in git 2.24.
    minVersion: ToolVersion(2, 24, 0),
    docsUrl: 'https://git-scm.com/downloads',
  ),
  ToolSpec(
    bin: 'glab',
    tier: ToolTier.feature,
    purpose: 'GitLab: merge requests, pipelines, issues, CI logs.',
    docsUrl: 'https://gitlab.com/gitlab-org/cli#installation',
  ),
  ToolSpec(
    bin: 'gh',
    tier: ToolTier.feature,
    purpose: 'GitHub: pull requests, workflow runs, issues, releases.',
    // The GitHub panels rely on `gh pr list --json` / `gh run list --json`,
    // which need a reasonably modern gh (the `--json` flags landed in the 2.x
    // line). 2.0 is a conservative floor.
    minVersion: ToolVersion(2, 0, 0),
    docsUrl: 'https://cli.github.com/',
  ),
  ToolSpec(
    bin: 'fswatch',
    tier: ToolTier.optional,
    purpose:
        'Live refresh on file changes (macOS remote hosts). Falls back to '
        'polling when absent.',
    onlyOs: 'macos',
    docsUrl: 'https://github.com/emcrisostomo/fswatch',
  ),
  ToolSpec(
    bin: 'inotifywait',
    tier: ToolTier.optional,
    purpose:
        'Live refresh on file changes (Linux remote hosts). Falls back to '
        'polling when absent.',
    onlyOs: 'linux',
    docsUrl: 'https://github.com/inotify-tools/inotify-tools',
  ),
];

/// Looks up a tool's spec by binary name, or null if it isn't in the catalog.
ToolSpec? toolSpecFor(String bin) {
  for (final t in kToolCatalog) {
    if (t.bin == bin) return t;
  }
  return null;
}

/// Binaries the connect-time probe resolves for a *capability*, not because the
/// user ever names them: they are never `argv[0]` of a command we build, never
/// shown in the doctor, and never overridable.
///
///  * `gzip` — load-bearing. Its presence in the probe's `found` map is what
///    lets the executor compress large reads on the wire; a host without it
///    just transfers uncompressed (see `SSHCommandExecutor`'s `compress`).
///  * `stdbuf` — probed so the augmented PATH is known to cover it. The remote
///    watcher runs `stdbuf -oL inotifywait` *inside* an `sh -c` script and
///    falls back to bare `inotifywait` when it's missing, so it resolves by
///    name at run time rather than through `argv[0]` rewriting.
const List<String> kProbedCapabilities = ['stdbuf', 'gzip'];

/// The binaries the user may override a path for — every tool in the catalog,
/// and only those. A capability ([kProbedCapabilities]) is not something the
/// user names, so it is not overridable.
final List<String> kOverridableBinaries = [for (final t in kToolCatalog) t.bin];

/// Everything the connect-time probe looks for: the catalog plus the
/// capabilities. The probe script is generated from this — it is not a
/// hand-written list that has to be kept in step.
final List<String> kProbedBinaries = [
  ...kOverridableBinaries,
  ...kProbedCapabilities,
];

/// A labeled, copy-pasteable install command block.
class InstallHint {
  final String label;
  final String command;
  const InstallHint(this.label, this.command);
}

/// Platform-aware install/upgrade guidance for [bin] on [os] ('macos' |
/// 'linux' | anything else → generic). We only detect the OS family, not the
/// Linux distro, so Linux returns both apt- and dnf-based options plus a
/// rootless fallback for locked-down bastions where the user has no sudo.
List<InstallHint> installHints(String bin, String os) {
  if (os == 'macos') return _macHints(bin);
  if (os == 'linux') return _linuxHints(bin);
  // Unknown host: offer the most universal guidance (Homebrew works on macOS
  // and Linux) plus a pointer to the docs.
  return [
    if (bin != 'inotifywait')
      InstallHint('Homebrew (macOS/Linux)', 'brew install $bin'),
  ];
}

List<InstallHint> _macHints(String bin) => switch (bin) {
  'git' => const [
    InstallHint('Xcode Command Line Tools', 'xcode-select --install'),
    InstallHint('Homebrew', 'brew install git'),
  ],
  'glab' => const [InstallHint('Homebrew', 'brew install glab')],
  'gh' => const [InstallHint('Homebrew', 'brew install gh')],
  'fswatch' => const [InstallHint('Homebrew', 'brew install fswatch')],
  // inotifywait is Linux-only; nothing to install on macOS.
  _ => const [],
};

List<InstallHint> _linuxHints(String bin) => switch (bin) {
  'git' => const [
    InstallHint('Debian / Ubuntu', 'sudo apt install git'),
    InstallHint('RHEL / Fedora', 'sudo dnf install git'),
  ],
  'gh' => const [
    InstallHint(
      'Debian / Ubuntu (official repo)',
      'sudo mkdir -p -m 755 /etc/apt/keyrings\n'
          'wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null\n'
          'sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg\n'
          'echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null\n'
          'sudo apt update && sudo apt install gh',
    ),
    InstallHint('RHEL / Fedora', 'sudo dnf install gh'),
    InstallHint(
      'No sudo (rootless, ~/.local/bin)',
      'gh ships a static binary — download the linux tarball from '
          'https://github.com/cli/cli/releases and extract it into ~/.local:\n'
          'tar -xzf gh_*_linux_amd64.tar.gz -C ~/.local --strip-components=1',
    ),
  ],
  'glab' => const [
    InstallHint('Snap', 'sudo snap install glab'),
    InstallHint('Fedora', 'sudo dnf install glab'),
    InstallHint(
      'No sudo (rootless, ~/.local/bin)',
      'glab ships a static binary — download the linux tarball from '
          'https://gitlab.com/gitlab-org/cli/-/releases and extract it into '
          '~/.local/bin:\n'
          'tar -xzf glab_*_Linux_x86_64.tar.gz -C ~/.local/bin --strip-components=1',
    ),
  ],
  'inotifywait' => const [
    InstallHint('Debian / Ubuntu', 'sudo apt install inotify-tools'),
    InstallHint(
      'RHEL / Rocky / Alma (needs EPEL)',
      'sudo dnf install epel-release && sudo dnf install inotify-tools',
    ),
    InstallHint('Fedora', 'sudo dnf install inotify-tools'),
  ],
  // fswatch is macOS-only in this app.
  _ => const [],
};
