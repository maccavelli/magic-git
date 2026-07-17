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
/// Shared by forge detection and both CLI services' host resolution.
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

/// The path component of a git remote URL — `.git` suffix stripped, no
/// leading slash: `git@host:group/repo.git` → `group/repo`,
/// `https://host/owner/repo` → `owner/repo`. Returns null when the URL can't
/// be parsed. GitLab keeps the whole (possibly nested) path; GitHub callers
/// split it into owner/name.
String? remotePathFromUrl(String url) {
  var path = url.trim();
  if (path.isEmpty) return null;
  if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
  if (path.contains('://')) {
    final uri = Uri.tryParse(path);
    if (uri == null) return null;
    path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
  } else {
    final colon = path.indexOf(':');
    if (colon < 0) return null;
    path = path.substring(colon + 1);
  }
  return path.isEmpty ? null : path;
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

/// `-c credential.helper=…` argv fragments that make a single `git` invocation
/// authenticate HTTPS forge remotes via the matching CLI (`gh` / `glab`),
/// without mutating the host's permanent git config.
///
/// Why this exists: Magic Git creates forge projects through `gh`/`glab` (which
/// use their own auth stores) but owns `git push` itself so the nested CLI
/// git never runs under a bare GUI/SSH PATH. Plain `git push` over HTTPS does
/// **not** consult `gh auth` unless a credential helper is configured — and a
/// host-wide helper that answers for *every* host (e.g. a glab-only wrapper)
/// will feed the wrong password to github.com, producing GitHub's
/// "Support for password authentication was removed" even when `gh` is signed
/// in. Clearing ambient helpers and installing the forge CLI for this one
/// command is the scoped fix: no permanent `gh auth setup-git`, no tokens in
/// argv/env. SSH remotes ignore credential helpers, so this is a no-op for them.
///
/// Returns an empty list for [Forge.none] / [Forge.unknown] so custom remotes
/// keep using the host's ordinary credential setup.
List<String> forgeGitAuthConfigArgs(Forge forge) {
  final helper = switch (forge) {
    Forge.github => '!gh auth git-credential',
    Forge.gitlab => '!glab auth git-credential',
    Forge.none || Forge.unknown => null,
  };
  if (helper == null) return const [];
  return [
    '-c',
    'credential.helper=',
    '-c',
    'credential.helper=$helper',
  ];
}

/// Both forge CLI helpers, for commands that may touch several remotes
/// (e.g. `git fetch --all`). Same clear-first contract as
/// [forgeGitAuthConfigArgs].
List<String> forgeGitAuthConfigArgsAll() => const [
  '-c',
  'credential.helper=',
  '-c',
  'credential.helper=!gh auth git-credential',
  '-c',
  'credential.helper=!glab auth git-credential',
];

/// The outcome of resolving a just-created forge project's clone URL for
/// origin wiring: the URL itself (null when every source failed), plus a
/// human-readable trail of what was tried and why each source failed — the
/// create-repo sheet surfaces it in its warning banner and output log, so a
/// live wiring failure states its reason instead of a bare "could not be
/// determined".
typedef OriginUrlResolution = ({String? url, String detail});

/// Extracts the created project's clone URL from a forge CLI's own
/// `repo create` output, or null when no line carries one.
///
/// Both CLIs print the new project's web URL on success — `gh repo create`
/// prints it alone on stdout, `glab repo create` embeds it in a
/// `✓ Created project on GitLab: … - <url>` line (verified live against
/// gh 2.96 / glab 1.107). Reading it back is the *primary* origin-URL source:
/// zero extra round trips and immune to the post-create eventual-consistency
/// window that makes an immediate API lookup racy. The URL's final path
/// segment must equal [name] (case-insensitively, ignoring a `.git` suffix),
/// so an unrelated URL in the output can never be mistaken for the project.
/// The result is normalized to end in `.git`.
String? forgeUrlFromCreateOutput(String output, {required String name}) {
  if (output.isEmpty || name.isEmpty) return null;
  for (final m in RegExp(r'''https?://[^\s"'()<>]+''').allMatches(output)) {
    // Sentence punctuation attaches to an embedded URL; strip it before
    // comparing the last segment.
    final candidate = m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
    var base = candidate;
    if (base.endsWith('.git')) base = base.substring(0, base.length - 4);
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final slash = base.lastIndexOf('/');
    if (slash < 0) continue;
    final last = base.substring(slash + 1);
    if (last.toLowerCase() == name.toLowerCase()) return '$base.git';
  }
  return null;
}
