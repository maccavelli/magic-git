/// Structured authentication status for the external tools Magic Git drives
/// (`git`, `gh`, `glab`) on a single target — this Mac, or a connected SSH
/// host. Surfaced on the Dashboard so a user can see, at a glance, whether
/// every tool is present and signed in to the host they expect, instead of
/// discovering a stale/missing login only when a create/clone silently fails.
///
/// Parsing is **per host block**: both CLIs print each host at column 0
/// followed by an indented detail block, and a judgment (logged in, token
/// expired, 401) is only meaningful within its own block — one stale
/// secondary host must never mark the whole tool signed out, and an account
/// name must never be attributed to a different host's block.
library;

/// One tool's presence + sign-in state on a target.
class ToolAuth {
  /// Bare tool name: `git`, `gh`, or `glab`.
  final String tool;

  /// Whether the binary itself resolved on the target (a 127/spawn failure
  /// means it isn't on the PATH the app sees — the usual GUI-launch cause).
  final bool present;

  /// Whether the tool is signed in **with a working credential**. Always true
  /// for `git` (it has no login); for `gh`/`glab` a host whose token the CLI
  /// itself reports as failed/expired does NOT count.
  final bool authenticated;

  /// The check never completed (probe timeout / transport error) — nothing
  /// definitive is known. Rendered as a neutral "could not check", never as
  /// "signed out" or "installed".
  final bool checkFailed;

  /// The host the tool is signed in to (e.g. `github.com`,
  /// `gitlab.lkqdev.com`), or null when signed out / not applicable.
  final String? host;

  /// The signed-in account/user name, when the CLI reported one.
  final String? account;

  /// A short, human-readable one-line summary for display (the parsed reason
  /// when signed out, or the login line when signed in).
  final String detail;

  const ToolAuth({
    required this.tool,
    required this.present,
    required this.authenticated,
    this.checkFailed = false,
    this.host,
    this.account,
    this.detail = '',
  });

  /// The tool was not found on the target at all.
  factory ToolAuth.missing(String tool) => ToolAuth(
    tool: tool,
    present: false,
    authenticated: false,
    detail: 'Not found on the target — check the tool is installed and on '
        'the PATH the app sees.',
  );

  /// The probe never completed — timeout or transport failure. Deliberately
  /// distinct from signed-out: telling a signed-in user to re-login over a
  /// slow VPN is worse than admitting the check didn't finish.
  factory ToolAuth.unknown(String tool) => ToolAuth(
    tool: tool,
    present: true,
    authenticated: false,
    checkFailed: true,
    detail: 'Could not check — the probe timed out or failed to run.',
  );

  /// Overall health for a status dot: ok (green), warn (orange), bad (red),
  /// unknown (gray — the check itself didn't complete).
  ToolAuthLevel get level {
    if (checkFailed) return ToolAuthLevel.unknown;
    if (!present) return ToolAuthLevel.bad;
    if (!authenticated) return ToolAuthLevel.warn;
    return ToolAuthLevel.ok;
  }
}

enum ToolAuthLevel { ok, warn, bad, unknown }

/// The combined auth picture for one target.
class TargetAuth {
  /// Human label for the target (e.g. "This Mac", "work@ssh.example").
  final String label;

  /// True for this-Mac, false for an SSH host.
  final bool isLocal;
  final ToolAuth git;
  final ToolAuth gh;
  final ToolAuth glab;

  const TargetAuth({
    required this.label,
    required this.isLocal,
    required this.git,
    required this.gh,
    required this.glab,
  });

  /// Every tool row, in display order.
  List<ToolAuth> get tools => [git, gh, glab];

  /// True when at least one forge CLI is signed in — the target can publish.
  bool get anyForgeAuthenticated => gh.authenticated || glab.authenticated;
}

/// One host's chunk of `gh auth status` / `glab auth status` output: the
/// unindented host line plus its indented detail lines, joined for matching.
class _HostBlock {
  final String host;
  final String body;
  const _HostBlock(this.host, this.body);
}

/// Splits combined auth-status output into per-host blocks. Both CLIs print
/// each host at column 0 (some versions with a trailing colon) followed by an
/// indented detail block; anything unindented that isn't host-like (e.g.
/// "You are not logged in…" prose) ends the current block.
List<_HostBlock> _hostBlocks(String output) {
  // Hostname-ish: one token, letters/digits/dots/dashes, optional :port.
  // No dot required — self-hosted instances on single-label DNS names exist.
  final hostLike = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$');
  final blocks = <_HostBlock>[];
  String? host;
  var body = StringBuffer();
  void flush() {
    if (host != null) blocks.add(_HostBlock(host!, body.toString()));
    host = null;
    body = StringBuffer();
  }

  for (final raw in output.split('\n')) {
    if (raw.trim().isEmpty) continue;
    final indented = raw.startsWith(' ') || raw.startsWith('\t');
    if (indented) {
      if (host != null) body.writeln(raw);
      continue;
    }
    flush();
    final line = raw.trim().replaceFirst(RegExp(r':$'), '');
    if (hostLike.hasMatch(line)) host = line;
  }
  flush();

  // Fallback: when no bare hostname line was found (e.g. glab output starts
  // with "✓ Logged in to <host>" before the host line), extract hosts from
  // "Logged in to <host>" lines anywhere in the output.
  if (blocks.isEmpty) {
    for (final raw in output.split('\n')) {
      final m = RegExp(r'Logged in to (\S+)').firstMatch(raw);
      if (m != null) {
        blocks.add(_HostBlock(m.group(1)!, raw));
      }
    }
  }

  return blocks;
}

/// Whether a single host's block reports a *working* login: a "Logged in to"
/// line, and no failure marker for that same host. Both CLIs put the failure
/// on its own line (`X … Failed to log in…`, `x host: API call failed … 401`),
/// so judging inside the block can't be poisoned by a different host's state.
bool _blockLoggedIn(_HostBlock b) {
  final failed = RegExp(
    r'(Failed to log in|API call failed|not logged in)',
    caseSensitive: false,
  ).hasMatch(b.body);
  return b.body.contains('Logged in to') && !failed;
}

/// Parses `gh auth status` (stdout+stderr combined) into a [ToolAuth].
///
/// [present] should be false when the command failed to spawn (exit 127) — a
/// missing binary. gh can be signed in to several hosts; the block whose
/// details contain `Active account: true` is the one gh will actually use, so
/// that block alone decides the state — and the account name is read from
/// that same block, never from another host's.
ToolAuth parseGhAuthStatus(String output, {required bool present}) {
  if (!present) return ToolAuth.missing('gh');
  final blocks = _hostBlocks(output);
  if (blocks.isEmpty) {
    return const ToolAuth(
      tool: 'gh',
      present: true,
      authenticated: false,
      detail: 'Signed out — run `gh auth login` on the target.',
    );
  }
  _HostBlock active = blocks.first;
  for (final b in blocks) {
    if (b.body.contains('Active account: true')) {
      active = b;
      break;
    }
  }
  if (!_blockLoggedIn(active)) {
    // A host is configured but its token no longer works (expired/revoked) —
    // a distinct, actionable state: the fix is re-login, and any forge call
    // through it would 401.
    return ToolAuth(
      tool: 'gh',
      present: true,
      authenticated: false,
      host: active.host,
      detail: 'Token for ${active.host} is expired or invalid — run '
          '`gh auth login` on the target.',
    );
  }
  final account = RegExp(r'account\s+(\S+)').firstMatch(active.body)?.group(1);
  return ToolAuth(
    tool: 'gh',
    present: true,
    authenticated: true,
    host: active.host,
    account: account,
    detail: account == null
        ? 'Signed in to ${active.host}'
        : 'Signed in to ${active.host} as $account',
  );
}

/// Parses `glab auth status` (stdout+stderr combined) into a [ToolAuth].
///
/// glab prints `✓ Logged in to <host> as <user>` per working host and
/// `x <host>: API call failed … 401` for a stale one — and is known to exit 0
/// even on a 401 (glab #911), so the state is judged from the output text
/// alone. The first host block with a *working* login wins; a stale secondary
/// host never marks the whole tool signed out.
ToolAuth parseGlabAuthStatus(String output, {required bool present}) {
  if (!present) return ToolAuth.missing('glab');
  final blocks = _hostBlocks(output);
  _HostBlock? working;
  for (final b in blocks) {
    if (_blockLoggedIn(b)) {
      working = b;
      break;
    }
  }
  if (working == null) {
    if (blocks.isNotEmpty) {
      return ToolAuth(
        tool: 'glab',
        present: true,
        authenticated: false,
        host: blocks.first.host,
        detail: 'Token for ${blocks.first.host} is expired or invalid — run '
            '`glab auth login` on the target.',
      );
    }
    return const ToolAuth(
      tool: 'glab',
      present: true,
      authenticated: false,
      detail: 'Signed out — run `glab auth login` on the target.',
    );
  }
  // `Logged in to <host> as <user>` — capture <user> from this block only.
  final account = RegExp(
    r'Logged in to \S+ as (\S+)',
  ).firstMatch(working.body)?.group(1);
  return ToolAuth(
    tool: 'glab',
    present: true,
    authenticated: true,
    host: working.host,
    account: account,
    detail: account == null
        ? 'Signed in to ${working.host}'
        : 'Signed in to ${working.host} as $account',
  );
}

/// Parses `git --version` into a [ToolAuth] (git needs no login, so it is
/// "authenticated" whenever present). [present] false ⇒ missing. Output with
/// no version token at all (the probe ran but printed nothing usable) is
/// reported as unknown rather than a confident "Installed".
ToolAuth parseGitVersion(String output, {required bool present}) {
  if (!present) return ToolAuth.missing('git');
  final m = RegExp(r'(\d+\.\d+(?:\.\d+)?)').firstMatch(output);
  if (m == null) return ToolAuth.unknown('git');
  return ToolAuth(
    tool: 'git',
    present: true,
    authenticated: true,
    detail: 'git ${m.group(1)}',
  );
}
