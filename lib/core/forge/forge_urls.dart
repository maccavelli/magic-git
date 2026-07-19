/// Web URLs for forge items, constructed from the repo's `origin` remote.
///
/// Some items carry an authoritative URL from the CLI's JSON (MR/pipeline
/// `web_url`, PR/run `url`) — callers should prefer those. Everything else
/// (issues, milestones, releases, the project itself) is addressed by the
/// forge's stable URL scheme over the project's web base, which both GitHub
/// and GitLab (including self-hosted, including nested GitLab groups) derive
/// from the same host + path a clone URL carries.
///
/// All helpers return null when the remote URL can't be parsed — callers
/// hide the affordance rather than launching a broken URL.
library;

import 'forge.dart';

/// `https://<host>/<path>` for the project behind [remoteUrl], or null.
/// The scheme is always https: ssh/scp remotes have no web scheme to reuse,
/// and every supported forge serves its UI over https.
String? forgeProjectWebUrl(String remoteUrl) {
  final host = forgeHostFromRemoteUrl(remoteUrl);
  final path = remotePathFromUrl(remoteUrl);
  if (host == null || path == null) return null;
  return 'https://$host/$path';
}

/// The issue page for issue [id]. GitLab pages live under the `/-/`
/// namespace; GitHub's under the project root.
String? forgeIssueWebUrl(String remoteUrl, Forge forge, int id) {
  final base = forgeProjectWebUrl(remoteUrl);
  if (base == null) return null;
  return switch (forge) {
    Forge.github => '$base/issues/$id',
    Forge.gitlab => '$base/-/issues/$id',
    Forge.none || Forge.unknown => null,
  };
}

/// The milestone page for milestone [id] (GitHub `number` / GitLab `iid`).
///
/// Prefer [ForgeMilestone.webUrl] from the payload when available: callers
/// that hold a REST-sourced milestone have a global `id`, NOT the iid this
/// path needs, so this reconstruction is only safe for GitHub (where `id` is
/// the `number` the path wants).
String? forgeMilestoneWebUrl(String remoteUrl, Forge forge, int id) {
  final base = forgeProjectWebUrl(remoteUrl);
  if (base == null) return null;
  return switch (forge) {
    Forge.github => '$base/milestone/$id',
    Forge.gitlab => '$base/-/milestones/$id',
    Forge.none || Forge.unknown => null,
  };
}

/// The release page for [tagName].
String? forgeReleaseWebUrl(String remoteUrl, Forge forge, String tagName) {
  final base = forgeProjectWebUrl(remoteUrl);
  if (base == null || tagName.isEmpty) return null;
  final tag = Uri.encodeComponent(tagName);
  return switch (forge) {
    Forge.github => '$base/releases/tag/$tag',
    Forge.gitlab => '$base/-/releases/$tag',
    Forge.none || Forge.unknown => null,
  };
}
