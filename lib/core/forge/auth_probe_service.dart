import '../ssh/ssh_command_executor.dart';
import 'auth_status.dart';
import 'forge.dart';

/// Runs the read-only tool checks — `git --version`, `gh auth status`,
/// `glab auth status` — on a target through the shared [CommandExecutor], and
/// folds the results into a [TargetAuth]. Best-effort: every probe is
/// independent, and a probe that can't complete (missing binary, timeout,
/// transport error) becomes the matching non-ok [ToolAuth] state rather than
/// an exception — a timed-out check reports *unknown*, never a confident
/// "signed out". Feeds the Dashboard's Authentication section and the create
/// wizard's pre-publish guard.
class AuthProbeService {
  final CommandExecutor _executor;
  const AuthProbeService(this._executor);

  /// Short per-command timeout — `gh`/`glab auth status` verify the token over
  /// the network, so this must never block a UI section indefinitely.
  static const Duration _timeout = Duration(seconds: 12);

  Future<TargetAuth> probe({
    required String label,
    required bool isLocal,
    String cwd = '.',
  }) async {
    // Run the three independent probes concurrently — they share the read lane
    // and don't touch the index, so overlapping is safe and much faster.
    final results = await Future.wait([
      _run(cwd, ['git', '--version']),
      _run(cwd, ['gh', 'auth', 'status']),
      _run(cwd, ['glab', 'auth', 'status']),
    ]);
    return TargetAuth(
      label: label,
      isLocal: isLocal,
      git: _fold('git', results[0], parseGitVersion),
      gh: _fold('gh', results[1], parseGhAuthStatus),
      glab: _fold('glab', results[2], parseGlabAuthStatus),
    );
  }

  /// Probes just one forge CLI's auth state — the create/clone flows' guard
  /// and host prefill, where only the selected forge matters and spawning the
  /// other two checks would be wasted round-trips.
  Future<ToolAuth> probeForgeCli(Forge forge, {String cwd = '.'}) async {
    final isGithub = forge == Forge.github;
    final cli = isGithub ? 'gh' : 'glab';
    final result = await _run(cwd, [cli, 'auth', 'status']);
    return _fold(
      cli,
      result,
      isGithub ? parseGhAuthStatus : parseGlabAuthStatus,
    );
  }

  ToolAuth _fold(
    String tool,
    _ProbeResult result,
    ToolAuth Function(String, {required bool present}) parse,
  ) {
    if (result.timedOut) return ToolAuth.unknown(tool);
    return parse(result.combined, present: result.present);
  }

  Future<_ProbeResult> _run(String cwd, List<String> argv) async {
    try {
      final r = await _executor.execute(
        repoPath: cwd,
        gitArgs: argv,
        lane: ExecLane.read,
        timeout: _timeout,
      );
      // Exit 127 is "command not found" from both the local spawn path
      // (ProcessException mapped to 127) and a remote shell — the tool isn't
      // on the PATH the app sees. Any other exit means the tool ran (it may
      // still report signed-out in its output, which the parsers handle).
      return _ProbeResult(
        present: r.exitCode != 127,
        combined: '${r.stdout}\n${r.stderr}',
      );
    } catch (_) {
      // Timeout or transport error — the check never completed, so nothing
      // definitive is known. Marked as such rather than mapped onto a state
      // ("signed out", "installed") the probe never actually observed.
      return const _ProbeResult(present: true, combined: '', timedOut: true);
    }
  }
}

class _ProbeResult {
  final bool present;
  final String combined;
  final bool timedOut;
  const _ProbeResult({
    required this.present,
    required this.combined,
    this.timedOut = false,
  });
}
