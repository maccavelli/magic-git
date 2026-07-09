import 'forge.dart';

/// One repository in a forge account listing (`gh repo list` / the GitLab
/// projects API), as shown by the clone sheet's browse tab.
class ForgeRepoSummary {
  /// `owner/name` (GitHub `nameWithOwner`) or the GitLab
  /// `path_with_namespace` — the identifier the forge CLI's clone command
  /// accepts directly.
  final String slug;
  final String description;
  final bool isPrivate;
  final String webUrl;
  final String sshUrl;

  /// ISO-8601 last-activity timestamp, when the API provided one.
  final String? updatedAt;
  final Forge forge;

  const ForgeRepoSummary({
    required this.slug,
    required this.description,
    required this.isPrivate,
    required this.webUrl,
    required this.sshUrl,
    required this.updatedAt,
    required this.forge,
  });

  /// The repository name without its owner/namespace — the default clone
  /// directory name.
  String get name {
    final i = slug.lastIndexOf('/');
    return i < 0 ? slug : slug.substring(i + 1);
  }

  /// From one element of `gh repo list --json
  /// nameWithOwner,description,isPrivate,url,sshUrl,updatedAt`.
  factory ForgeRepoSummary.fromGhJson(Map<String, dynamic> json) =>
      ForgeRepoSummary(
        slug: (json['nameWithOwner'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
        isPrivate: (json['isPrivate'] as bool?) ?? false,
        webUrl: (json['url'] as String?) ?? '',
        sshUrl: (json['sshUrl'] as String?) ?? '',
        updatedAt: json['updatedAt'] as String?,
        forge: Forge.github,
      );

  /// From one element of the GitLab `GET /projects?membership=true&simple=true`
  /// response. GitLab's `internal` visibility is treated as private for the
  /// badge — it isn't world-readable.
  factory ForgeRepoSummary.fromGlabJson(Map<String, dynamic> json) =>
      ForgeRepoSummary(
        slug: (json['path_with_namespace'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
        isPrivate: (json['visibility'] as String?) != 'public',
        webUrl: (json['web_url'] as String?) ?? '',
        sshUrl: (json['ssh_url_to_repo'] as String?) ?? '',
        updatedAt: json['last_activity_at'] as String?,
        forge: Forge.gitlab,
      );
}
