import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
import '../github/github_project_panel.dart';
import '../gitlab/project_panel.dart';
import 'forge_panel.dart';

/// The "Project" sidebar tab. Like [ForgePanel], detects the repo's forge and
/// dispatches to the GitLab or GitHub project dashboard.
class ForgeProjectPanel extends ConsumerWidget {
  final String repoPath;

  const ForgeProjectPanel({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forge = ref.watch(forgeProvider(repoPath));
    return forge.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (f) => switch (f) {
        Forge.github => GitHubProjectPanel(repoPath: repoPath),
        Forge.gitlab => ProjectPanel(repoPath: repoPath),
        Forge.none => const NoRemoteNotice('project features'),
        Forge.unknown => const UnsupportedForgeNotice(),
      },
    );
  }
}
