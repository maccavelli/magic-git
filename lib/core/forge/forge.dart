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
    path = uri.path;
  } else {
    final colon = path.indexOf(':');
    if (colon < 0) return null;
    path = path.substring(colon + 1);
  }
  // Trim leading and trailing slashes uniformly: `/group/repo`, `group/repo/`
  // and `group/repo` all name the same project — a kept trailing slash
  // otherwise becomes part of the GitLab project id and 404s.
  path = path.replaceAll(RegExp(r'^/+|/+$'), '');
  return path.isEmpty ? null : path;
}

/// Classifies a remote [host] as a known forge by hostname alone.
///
/// Recognizes the `github`/`gitlab` telltale as a whole dot-separated label —
/// `github.com`, `gitlab.mycorp.com`, `git.gitlab.io` — which catches both the
/// public hosts and common self-hosted naming, without the false positives an
/// unanchored substring match produces (`mygithub-mirror.example`, or a GitLab
/// vanity host that merely *contains* `github`). A host that carries both
/// telltales, or neither, is ambiguous and falls through to [Forge.unknown];
/// the provider layer resolves those by asking the CLIs which hosts they're
/// authenticated to (see [authStatusListsHost]) rather than guessing by which
/// forge happened to be tested first.
Forge classifyForgeHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return Forge.unknown;
  final isGithub = RegExp(r'(^|\.)github(\.|$)').hasMatch(h);
  final isGitlab = RegExp(r'(^|\.)gitlab(\.|$)').hasMatch(h);
  if (isGithub && !isGitlab) return Forge.github;
  if (isGitlab && !isGithub) return Forge.gitlab;
  return Forge.unknown;
}

/// Whether a `gh`/`glab auth status` dump reports being signed in to [host],
/// matched as an exact host token — a column-0 host header (`github.com`) or a
/// `Logged in to <host>` line — never as an incidental substring of a tip URL
/// or a longer configured host. Forge detection's self-hosted fallback uses
/// this to classify an unrecognized host by which CLI owns it, so a stray
/// mention of the host string elsewhere in the output can't misclassify it.
bool authStatusListsHost(String statusOutput, String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  for (final raw in statusOutput.split('\n')) {
    final line = raw.trim().toLowerCase();
    if (line == h) return true;
    final m = RegExp(r'logged in to (\S+)').firstMatch(line);
    if (m != null && m.group(1) == h) return true;
  }
  return false;
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
///
/// [ghPath]/[glabPath] pin the helper to the connect-time-resolved absolute
/// path of that CLI (see [_forgeCredentialHelper]); pass them so git's
/// credential subprocess can't re-resolve a shadowing shim on PATH.
List<String> forgeGitAuthConfigArgs(
  Forge forge, {
  String? ghPath,
  String? glabPath,
}) {
  final helper = switch (forge) {
    Forge.github => _forgeCredentialHelper('gh', ghPath),
    Forge.gitlab => _forgeCredentialHelper('glab', glabPath),
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
/// [forgeGitAuthConfigArgs]; [ghPath]/[glabPath] pin the resolved absolute
/// paths (see [_forgeCredentialHelper]).
List<String> forgeGitAuthConfigArgsAll({String? ghPath, String? glabPath}) => [
  '-c',
  'credential.helper=',
  '-c',
  'credential.helper=${_forgeCredentialHelper('gh', ghPath)}',
  '-c',
  'credential.helper=${_forgeCredentialHelper('glab', glabPath)}',
];

/// The `!<cli> auth git-credential` value for a `credential.helper` `-c`
/// override. Pinned to [resolvedPath] (the connect-time-discovered absolute
/// path) when known, so git's credential subprocess — which re-resolves the
/// helper's command against the exec environment's `$PATH` — cannot pick up a
/// system-wide `gh`/`glab` shim that shadows the user's real CLI (the failure
/// that breaks HTTPS forge auth with "could not read Username"). Falls back to
/// the bare [cli] name when the path is unknown (an unconfigured executor, or a
/// relay proxy that holds no environment): still correct, since the augmented
/// PATH is exported for the command and now prefers per-user dirs.
///
/// The resolved path is embedded unquoted, matching the working host-managed
/// helper format (`!/home/u/.local/bin/glab auth git-credential`); every real
/// gh/glab install path is whitespace-free.
String _forgeCredentialHelper(String cli, String? resolvedPath) {
  final bin = (resolvedPath != null && resolvedPath.isNotEmpty)
      ? resolvedPath
      : cli;
  return '!$bin auth git-credential';
}

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
    final last = base.substring(slash + 1).toLowerCase();
    // Accept the raw name (GitHub keeps it verbatim) OR its slug: GitLab
    // derives the project's URL path by slugifying the name, so `"My Repo"` is
    // created at `.../my-repo` and a strict name-equality check would miss it,
    // dropping the round-trip-free origin-URL read.
    if (last == name.toLowerCase() || last == _forgePathSlug(name)) {
      return '$base.git';
    }
  }
  return null;
}

/// Slugifies a project [name] the way GitLab derives its URL path: lowercased,
/// each run of characters outside `[a-z0-9._-]` collapsed to a single `-`, and
/// leading/trailing `-`/`.` trimmed. `"My Repo"` → `my-repo`.
String _forgePathSlug(String name) => name
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
    .replaceAll(RegExp(r'-{2,}'), '-')
    .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
