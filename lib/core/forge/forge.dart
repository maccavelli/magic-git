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
