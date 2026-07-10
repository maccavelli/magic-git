/// Which code-hosting "forge" a repository's remote points at. Magic Git drives
/// a forge-specific CLI (`glab` for GitLab, `gh` for GitHub) for merge/pull
/// requests, CI, issues, and releases; everything else in the app is
/// forge-agnostic (plain git over the shared [CommandExecutor]).
///
/// [Forge.none] means the repo has no usable remote at all; [Forge.unknown]
/// means it has one but the host isn't a recognized GitHub/GitLab instance
/// (e.g. a self-hosted server we couldn't classify by hostname alone — the
/// provider layer may then consult the CLIs' own configured host lists before
/// giving up).
library;

/// A code-hosting provider, as detected from a repo's `origin` remote.
enum Forge { github, gitlab, none, unknown }

/// Extracts the host from a git remote URL. Handles scp-like
/// (`git@host:owner/repo.git`), `ssh://`, and `https://`/`http://` forms.
/// Returns null when no host can be parsed.
///
/// Mirrors the host parsing `GlabService` does internally (`_hostFromRemote`),
/// promoted here so forge detection can share it without depending on the
/// GitLab layer.
String? forgeHostFromRemoteUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.contains('://')) {
    // scp-like syntax: [user@]host:path
    final m = RegExp(r'^(?:[^@/]+@)?([^/:]+):').firstMatch(trimmed);
    return m?.group(1);
  }
  final host = Uri.tryParse(trimmed)?.host;
  return (host != null && host.isNotEmpty) ? host : null;
}

/// Classifies a remote [host] as a known forge by hostname alone.
///
/// Recognizes `github.com` / `*.github.com` and `gitlab.com` / `*.gitlab.com`
/// by exact suffix, plus a looser substring match (`github`/`gitlab`) that
/// catches common self-hosted naming (`github.mycorp.com`, `gitlab.internal`).
/// A GitHub Enterprise / GitLab instance on a custom domain with no telltale
/// substring falls through to [Forge.unknown]; the provider layer resolves
/// those by asking the CLIs which hosts they're authenticated to.
Forge classifyForgeHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return Forge.unknown;
  if (h == 'github.com' || h.endsWith('.github.com') || h.contains('github')) {
    return Forge.github;
  }
  if (h == 'gitlab.com' || h.endsWith('.gitlab.com') || h.contains('gitlab')) {
    return Forge.gitlab;
  }
  return Forge.unknown;
}

/// Classifies a forge straight from a remote URL. Returns [Forge.none] for a
/// blank/unparseable URL (treated as "no remote"), else the host
/// classification (which may be [Forge.unknown]).
Forge forgeFromRemoteUrl(String url) {
  final host = forgeHostFromRemoteUrl(url);
  if (host == null) return Forge.none;
  return classifyForgeHost(host);
}

/// Extracts the signed-in host from `gh auth status` / `glab auth status`
/// output (both CLIs print the same shape: each host at column 0 followed by
/// an indented detail block). Used to prefill the wizards' forge-host fields
/// with the instance the user is actually authenticated to, instead of the
/// stock github.com/gitlab.com default.
///
/// gh can be signed in to several hosts at once — the block whose details
/// contain `Active account: true` wins; otherwise the first host listed.
/// Returns null when nothing host-like appears (signed out, CLI missing —
/// its "You are not logged in…" prose has spaces and never matches).
/// [output] should be stdout+stderr combined: glab historically prints
/// status to stderr.
String? parseCliAuthHost(String output) {
  // Hostname-ish: one token, letters/digits/dots/dashes, optional :port.
  // Deliberately does NOT require a dot — self-hosted instances on internal
  // single-label DNS names are real.
  final hostLike = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$');
  String? first;
  String? current;
  for (final raw in output.split('\n')) {
    if (raw.trim().isEmpty) continue;
    final indented = raw.startsWith(' ') || raw.startsWith('\t');
    // Some CLI versions suffix the host line with a colon.
    final line = raw.trim().replaceFirst(RegExp(r':$'), '');
    if (!indented) {
      if (hostLike.hasMatch(line)) {
        current = line;
        first ??= line;
      } else {
        current = null;
      }
    } else if (current != null && raw.contains('Active account: true')) {
      return current;
    }
  }
  return first;
}
