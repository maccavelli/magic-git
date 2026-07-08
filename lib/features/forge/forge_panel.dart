import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
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
    return forge.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (f) => switch (f) {
        Forge.github => GitHubPanel(repoPath: repoPath, isActive: isActive),
        Forge.gitlab => GitLabPanel(repoPath: repoPath, isActive: isActive),
        Forge.none => const NoRemoteNotice('forge features'),
        Forge.unknown => const UnsupportedForgeNotice(),
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
