import 'dart:typed_data';

import '../ssh/ssh_command_executor.dart';
import 'install_planner.dart';

/// Runs on-host capability detection and (approved) tool installs through the
/// active [CommandExecutor], so guided install works identically on a local or
/// remote backend. Pairs with [planInstall], which decides *what* is safe to
/// run from what this probes.
class InstallService {
  final CommandExecutor _executor;
  const InstallService(this._executor);

  /// One round trip: does sudo run without a password prompt, and which package
  /// managers are on PATH? `sudo -n true` is a no-op that fails fast (rather
  /// than hanging on a prompt) when a password would be required. The augmented
  /// PATH the executor is already configured with is what makes a Homebrew
  /// `brew` resolve here.
  Future<HostCapabilities> probeCapabilities(String repoPath) async {
    const script =
        'if sudo -n true 2>/dev/null; then echo SUDO=1; else echo SUDO=0; fi; '
        'echo "ARCH=\$(uname -m)"; '
        'for m in brew apt-get dnf snap; do '
        'command -v "\$m" >/dev/null 2>&1 && echo "PM=\$m"; '
        'done';
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      timeout: const Duration(seconds: 20),
      lane: ExecLane.read,
    );
    if (!result.isSuccess) return const HostCapabilities();

    var sudo = false;
    var brew = false, apt = false, dnf = false, snap = false;
    var arch = '';
    for (final line in result.stdout.split('\n')) {
      final l = line.trim();
      if (l == 'SUDO=1') sudo = true;
      if (l == 'PM=brew') brew = true;
      if (l == 'PM=apt-get') apt = true;
      if (l == 'PM=dnf') dnf = true;
      if (l == 'PM=snap') snap = true;
      if (l.startsWith('ARCH=')) arch = _normalizeArch(l.substring(5));
    }
    return HostCapabilities(
      hasBrew: brew,
      hasApt: apt,
      hasDnf: dnf,
      hasSnap: snap,
      passwordlessSudo: sudo,
      arch: arch,
    );
  }

  /// Maps `uname -m` output to a release-asset arch token, or '' if unknown.
  static String _normalizeArch(String raw) => switch (raw.trim()) {
    'x86_64' || 'amd64' => 'amd64',
    'aarch64' || 'arm64' => 'arm64',
    _ => '',
  };

  /// Sideloads [bytes] (a static binary or a `.tar.gz` the user chose on their
  /// own machine) as [bin] onto the host: makes a temp dir, uploads the file
  /// into it over the executor's transport, then extracts/installs it into
  /// `~/.local/bin` and verifies it runs. Returns the install step's result (a
  /// non-zero exit is returned, not thrown). [filename] is used only for its
  /// basename (to preserve a `.tar.gz` suffix the install step keys on).
  Future<SSHCommandResult> sideload({
    required String repoPath,
    required String bin,
    required Uint8List bytes,
    required String filename,
  }) async {
    // 1. A private temp dir on the host to receive the upload.
    final mk = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', r'd=$(mktemp -d) && printf %s "$d"'],
      timeout: const Duration(seconds: 20),
    );
    if (!mk.isSuccess || mk.stdout.trim().isEmpty) {
      return const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'could not create a temporary directory on the host',
      );
    }
    final tmp = mk.stdout.trim();
    final base = filename.split(RegExp(r'[\\/]')).last;
    final remotePath = '$tmp/$base';

    // 2. Upload (SFTP over SSH, or a filesystem write locally).
    await _executor.uploadBytes(remotePath, bytes);

    // 3. Extract/install into ~/.local/bin, cleanup, arch sanity-check. Inputs
    // go via env so a user-chosen filename can never inject shell.
    return _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', kSideloadScript],
      extraEnv: {'SL_FILE': remotePath, 'SL_BIN': bin, 'SL_TMP': tmp},
      timeout: const Duration(minutes: 5),
      // Sync lane: writes ~/.local/bin on the host, never the repo — safe
      // alongside reads, but a 5-minute install must not block them.
      lane: ExecLane.sync,
    );
  }

  /// Runs an approved install [command] on the host and returns its raw result
  /// (a non-zero exit is returned, not thrown — the caller logs it). Installs
  /// can be slow (a Homebrew formula, a package-manager cache refresh), so the
  /// timeout is generous.
  Future<SSHCommandResult> run(String repoPath, String command) {
    return _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', command],
      timeout: const Duration(minutes: 10),
      // Sync lane: a package-manager install touches the host, not the repo —
      // reads keep flowing during a slow (up to 10-minute) install.
      lane: ExecLane.sync,
    );
  }
}
