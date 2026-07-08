/// Decides whether — and how — Magic Git can install a missing tool on the
/// connected host *without any interaction*, given what the host offers.
///
/// The hard constraint shaping every rule here: commands run over a
/// non-interactive channel (an SSH exec channel has no TTY; a Finder-launched
/// local app inherits an equally bare environment). So a command that would
/// prompt — notably `sudo` asking for a password — must never be auto-run. We
/// only produce a runnable [InstallCommand] when it needs no input:
///   * Homebrew on macOS (`brew install …`, no sudo), or
///   * a Linux package manager behind **passwordless** sudo (`sudo -n …`).
/// Anything else returns [InstallManual] with a reason, and the caller falls
/// back to copy-paste guidance (see `installHints`).
library;

/// What the connected host offers, discovered once by
/// `InstallService.probeCapabilities`.
class HostCapabilities {
  final bool hasBrew;
  final bool hasApt;
  final bool hasDnf;
  final bool hasSnap;

  /// `sudo -n true` succeeded — sudo runs without prompting for a password, so
  /// a privileged install can complete non-interactively.
  final bool passwordlessSudo;

  /// The host CPU architecture, normalized to a release-asset token (`amd64` |
  /// `arm64`), or '' if unknown/unrecognized. Used to tell the user exactly
  /// which binary to download for a sideload.
  final String arch;

  const HostCapabilities({
    this.hasBrew = false,
    this.hasApt = false,
    this.hasDnf = false,
    this.hasSnap = false,
    this.passwordlessSudo = false,
    this.arch = '',
  });

  bool get hasAnyLinuxPackageManager => hasApt || hasDnf || hasSnap;
}

/// The outcome of planning an install for one tool.
sealed class InstallAction {
  const InstallAction();
}

/// A command Magic Git can run on the host as-is, no interaction required.
class InstallCommand extends InstallAction {
  final String label; // e.g. "Homebrew", "apt", "download (~/.local/bin)"
  final String command; // the exact command to execute

  /// A human description shown in place of [command] when the command is a long
  /// script (e.g. the rootless download+verify). Null for short one-liners,
  /// which are readable as-is.
  final String? summary;

  const InstallCommand(this.label, this.command, {this.summary});

  /// What to show a human: the [summary] if the raw [command] is too long to
  /// read, else the command itself.
  String get describe => summary ?? command;
}

/// No safe one-click path exists; the caller shows [reason] and the copy-paste
/// install hints instead.
class InstallManual extends InstallAction {
  final String reason;
  const InstallManual(this.reason);
}

/// Standard reasons, so the UI and tests agree on wording.
const String kNeedsSudoReason =
    'Installing this needs sudo, which cannot prompt for a password over this '
    'connection. Copy a command below and run it in a terminal on the host.';
const String kNoBrewReason =
    'Homebrew was not found on the host. Install Homebrew first, or use a '
    'command below.';
const String kManualStepsReason =
    'This install needs manual setup (e.g. adding a signing key). Copy a '
    'command below and run it on the host.';
const String kNoPackageManagerReason =
    'No supported package manager was detected. Use a command below.';

/// Plans an interaction-free install of [bin] for [os] given [caps]. Returns an
/// [InstallCommand] only when it can run with no prompts; otherwise
/// [InstallManual].
InstallAction planInstall(String bin, String os, HostCapabilities caps) {
  if (os == 'macos') return _planMac(bin, caps);
  if (os == 'linux') return _planLinux(bin, caps);
  return const InstallManual(kNoPackageManagerReason);
}

InstallAction _planMac(String bin, HostCapabilities caps) {
  // Everything Magic Git needs on macOS is a Homebrew formula (git too — a
  // brew git works even though `xcode-select` is the other route). No sudo.
  if (bin == 'inotifywait') {
    return const InstallManual('inotifywait is a Linux-only tool.');
  }
  if (!caps.hasBrew) return const InstallManual(kNoBrewReason);
  return InstallCommand('Homebrew', 'brew install $bin');
}

InstallAction _planLinux(String bin, HostCapabilities caps) {
  final pw = caps.passwordlessSudo;
  switch (bin) {
    // gh and glab ship a single static binary, so they always have a rootless,
    // checksum-verified download path into ~/.local/bin — no sudo needed. We
    // still prefer a system package (dnf/snap) when passwordless sudo makes one
    // available, since it stays updated with the OS.
    case 'gh':
      if (pw && caps.hasDnf) {
        return const InstallCommand('dnf', 'sudo -n dnf install -y gh');
      }
      // The apt route needs GitHub's signing-key/repo setup, which we won't
      // auto-run — rootless download is the better fallback there.
      return _rootless('gh');

    case 'glab':
      if (pw && caps.hasDnf) {
        return const InstallCommand('dnf', 'sudo -n dnf install -y glab');
      }
      if (pw && caps.hasSnap) {
        return const InstallCommand('snap', 'sudo -n snap install glab');
      }
      return _rootless('glab');

    // git and inotifywait are only installable via a package manager, which
    // needs root — without passwordless sudo we can't run one non-interactively.
    case 'git':
      if (!pw) return const InstallManual(kNeedsSudoReason);
      if (caps.hasApt) {
        return const InstallCommand('apt', 'sudo -n apt-get install -y git');
      }
      if (caps.hasDnf) {
        return const InstallCommand('dnf', 'sudo -n dnf install -y git');
      }
      return const InstallManual(kNoPackageManagerReason);

    case 'inotifywait':
      if (!pw) return const InstallManual(kNeedsSudoReason);
      if (caps.hasApt) {
        return const InstallCommand(
          'apt',
          'sudo -n apt-get install -y inotify-tools',
        );
      }
      if (caps.hasDnf) {
        // EPEL carries inotify-tools on RHEL/Rocky/Alma; installing
        // epel-release is a harmless no-op where it's already present or on
        // Fedora (the package simply isn't needed there, but the combined
        // install still resolves inotify-tools from the base repo).
        return const InstallCommand(
          'dnf',
          'sudo -n dnf install -y epel-release inotify-tools',
        );
      }
      return const InstallManual(kNoPackageManagerReason);

    default:
      return const InstallManual(kNoPackageManagerReason);
  }
}

/// The tools that ship a single static binary we know how to fetch rootlessly.
const Set<String> kRootlessTools = {'gh', 'glab'};

/// Builds the rootless-download [InstallCommand] for [bin].
InstallCommand _rootless(String bin) => InstallCommand(
  'download (~/.local/bin)',
  rootlessInstallScript(bin),
  summary:
      'Download the official $bin binary, verify its SHA-256 checksum, and '
      'install it to ~/.local/bin — no admin rights required (needs outbound '
      'network access on the host).',
);

/// A self-contained POSIX-sh script that downloads the latest official static
/// binary for [bin] (`gh` or `glab`), verifies it against the release's
/// published SHA-256 checksums, and installs it into `~/.local/bin` (which the
/// environment probe already searches). Linux-only — on macOS we use Homebrew.
///
/// Safety: the archive is checksum-verified before anything is installed, the
/// download prefers `curl` and falls back to `wget`, and a temp dir is cleaned
/// up on exit. It never needs sudo. If the host has no outbound network access
/// (a truly air-gapped bastion), the download fails cleanly and the error is
/// surfaced — that case is what SFTP sideload (future work) is for.
String rootlessInstallScript(String bin) => switch (bin) {
  'gh' => _kGhRootless,
  'glab' => _kGlabRootless,
  _ => throw ArgumentError('no rootless install script for "$bin"'),
};

// uname -m → release arch token (amd64/arm64), shared by both scripts.
const String _kArchPreamble = r'''
set -eu
mkdir -p "$HOME/.local/bin"
m=$(uname -m)
case "$m" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported architecture: $m" >&2; exit 1 ;;
esac
dl() { curl -fsSL "$1" -o "$2" 2>/dev/null || wget -qO "$2" "$1"; }
fetch() { curl -fsSL "$1" 2>/dev/null || wget -qO- "$1"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
''';

const String _kGhRootless =
    _kArchPreamble +
    r'''
tag=$(fetch https://api.github.com/repos/cli/cli/releases/latest | grep -o '"tag_name":[ ]*"[^"]*"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
[ -n "$tag" ] || { echo "could not determine the latest gh version" >&2; exit 1; }
ver=${tag#v}
tarname="gh_${ver}_linux_${arch}.tar.gz"
base="https://github.com/cli/cli/releases/download/${tag}"
dl "$base/$tarname" "$tmp/$tarname"
dl "$base/gh_${ver}_checksums.txt" "$tmp/checksums.txt"
(cd "$tmp" && grep " ${tarname}$" checksums.txt | sha256sum -c -)
tar -xzf "$tmp/$tarname" -C "$tmp"
bin=$(find "$tmp" -type f -name gh | head -n1)
[ -n "$bin" ] || { echo "gh binary not found in the downloaded archive" >&2; exit 1; }
install -m 0755 "$bin" "$HOME/.local/bin/gh" 2>/dev/null || { cp "$bin" "$HOME/.local/bin/gh" && chmod 0755 "$HOME/.local/bin/gh"; }
echo "Installed gh ${ver} to $HOME/.local/bin/gh"
''';

/// Whether [bin] can be sideloaded (uploaded from the user's machine and
/// installed on the host) — the air-gapped fallback when the host can't reach
/// the internet. Same static-binary tools as the rootless download.
bool canSideload(String bin) => kRootlessTools.contains(bin);

/// The releases page for [bin], so the user can fetch the right artifact on a
/// machine that *does* have network access, then sideload it.
String releasesUrl(String bin) => switch (bin) {
  'gh' => 'https://github.com/cli/cli/releases/latest',
  'glab' => 'https://gitlab.com/gitlab-org/cli/-/releases',
  _ => '',
};

/// One-line guidance naming the exact artifact to download for a sideload of
/// [bin] onto a host of [arch] ('amd64'|'arm64'|'' if unknown).
String sideloadAssetHint(String bin, String arch) {
  final a = arch.isEmpty ? 'your host architecture' : 'linux_$arch';
  return 'On a machine with internet, download ${bin}_*_$a.tar.gz '
      '(or the raw $bin binary), then choose it here.';
}

/// A self-contained POSIX-sh script that installs an already-uploaded artifact
/// into `~/.local/bin`. Its inputs arrive as environment variables — never
/// interpolated into the script text — so a user-chosen filename can't inject
/// shell: `SL_FILE` (absolute path to the uploaded file), `SL_BIN` (target
/// tool name), `SL_TMP` (the temp dir to extract into and then remove).
///
/// It handles both a `.tar.gz`/`.tgz` archive (extract, locate the binary) and
/// a raw binary (used as-is), installs it 0755, cleans up, and finally runs
/// `<tool> --version` as an architecture sanity check — the most likely sideload
/// mistake is grabbing the wrong CPU/OS build, and a bare install would leave a
/// silently non-working binary otherwise. SSH transport already guarantees the
/// upload's integrity (the channel is MAC-protected), so no separate checksum
/// step is needed here.
const String kSideloadScript = r'''
set -eu
: "${SL_FILE:?}" "${SL_BIN:?}" "${SL_TMP:?}"
mkdir -p "$HOME/.local/bin"
case "$SL_FILE" in
  *.tar.gz|*.tgz)
    tar -xzf "$SL_FILE" -C "$SL_TMP"
    src=$(find "$SL_TMP" -type f -name "$SL_BIN" | head -n1)
    ;;
  *)
    src="$SL_FILE"
    ;;
esac
[ -n "$src" ] || { echo "$SL_BIN not found in the uploaded archive" >&2; exit 1; }
install -m 0755 "$src" "$HOME/.local/bin/$SL_BIN" 2>/dev/null || { cp "$src" "$HOME/.local/bin/$SL_BIN" && chmod 0755 "$HOME/.local/bin/$SL_BIN"; }
rm -rf "$SL_TMP"
if "$HOME/.local/bin/$SL_BIN" --version >/dev/null 2>&1; then
  echo "Installed $SL_BIN to $HOME/.local/bin/$SL_BIN"
else
  echo "Installed to ~/.local/bin/$SL_BIN, but it did not run — you may have chosen the wrong OS/architecture for this Linux host." >&2
  exit 1
fi
''';

const String _kGlabRootless =
    _kArchPreamble +
    r'''
tag=$(fetch 'https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest' | grep -o '"tag_name":[ ]*"[^"]*"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
[ -n "$tag" ] || { echo "could not determine the latest glab version" >&2; exit 1; }
ver=${tag#v}
tarname="glab_${ver}_linux_${arch}.tar.gz"
base="https://gitlab.com/gitlab-org/cli/-/releases/${tag}/downloads"
dl "$base/$tarname" "$tmp/$tarname"
dl "$base/checksums.txt" "$tmp/checksums.txt"
(cd "$tmp" && grep " ${tarname}$" checksums.txt | sha256sum -c -)
tar -xzf "$tmp/$tarname" -C "$tmp"
bin=$(find "$tmp" -type f -name glab | head -n1)
[ -n "$bin" ] || { echo "glab binary not found in the downloaded archive" >&2; exit 1; }
install -m 0755 "$bin" "$HOME/.local/bin/glab" 2>/dev/null || { cp "$bin" "$HOME/.local/bin/glab" && chmod 0755 "$HOME/.local/bin/glab"; }
echo "Installed glab ${ver} to $HOME/.local/bin/glab"
''';
