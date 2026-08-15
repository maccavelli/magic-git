import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
import '../common/repository_context.dart';
import '../forge/forge_workspace.dart';
import '../github/github_panel.dart';
import '../gitlab/gitlab_panel.dart';

/// The "Forge" sidebar tab. Detects the repo's forge from its `origin` remote
/// and dispatches to the GitLab or GitHub panel — the existing GitLab panel is
/// reused byte-for-byte for GitLab repos, so there's no regression to that path.
class ForgePanel extends ConsumerWidget {
  final String repoPath;
  final bool isActive;

  const ForgePanel({super.key, required this.repoPath, this.isActive = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forge = ref.watch(forgeProvider(repoPath));
    ref.listen(forgeProvider(repoPath), (previous, next) {
      final landed = next.value;
      if (landed == null) return;
      final connection = ref.read(connectionProvider);
      if (connection.sessionEpoch <= 0) return;
      final label = switch (landed) {
        Forge.github => 'GitHub',
        Forge.gitlab => 'GitLab',
        Forge.none => 'No forge remote',
        Forge.unknown => 'Unsupported forge',
      };
      ref
          .read(repositoryContextSupplementCacheProvider.notifier)
          .publish(
            RepositoryContextSupplementKey(
              repositoryIdentity: repositoryContextIdentityKey(
                backend: connection.backend.name,
                connectionId: connection.connectionId,
                repositoryPath: repoPath,
              ),
              sessionEpoch: connection.sessionEpoch,
            ),
            RepositoryContextSupplement(forgeLabel: label),
          );
    });
    // Four of the six outcomes used to render bare content with no context
    // bar, so the repository chrome disappeared while the forge was detecting,
    // failed to detect, or turned out to be absent. The shell is the same one
    // the happy paths use; only the canvas differs.
    return forge.when(
      loading: () => ForgeRepositoryWorkspace(
        repoPath: repoPath,
        forgeLabel: 'Forge',
        canvas: const SizedBox.shrink(),
        loading: true,
      ),
      error: (err, _) => ForgeRepositoryWorkspace(
        repoPath: repoPath,
        forgeLabel: 'Forge',
        canvas: const SizedBox.shrink(),
        error: err,
        onRetry: () => ref.invalidate(forgeProvider(repoPath)),
      ),
      data: (f) => switch (f) {
        Forge.github => GitHubPanel(repoPath: repoPath, isActive: isActive),
        Forge.gitlab => GitLabPanel(repoPath: repoPath, isActive: isActive),
        Forge.none => ForgeRepositoryWorkspace(
          repoPath: repoPath,
          forgeLabel: 'No forge remote',
          canvas: const NoRemoteNotice('forge features'),
        ),
        // The identity stays plain 'Forge' here: the canvas already says
        // "Unsupported forge" in full, and repeating it in the bar two
        // inches away is the same words twice, not more information.
        Forge.unknown => ForgeRepositoryWorkspace(
          repoPath: repoPath,
          forgeLabel: 'Forge',
          canvas: const UnsupportedForgeNotice(),
        ),
      },
    );
  }
}

/// Shown when the repo has a remote but its host isn't a recognized GitHub or
/// GitLab instance (and neither CLI reports being authenticated to it).
class UnsupportedForgeNotice extends StatelessWidget {
  const UnsupportedForgeNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Unsupported forge',
              style: typography.headline.copyWith(
                color: MacosColors.systemYellowColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "This repository's remote isn't a recognized GitHub or GitLab "
              'host, so forge features are unavailable.',
              textAlign: TextAlign.center,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
