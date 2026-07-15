import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/providers/app_providers.dart';
import '../common/async_views.dart';
import 'forge_panel.dart';
import 'project_dashboard_panel.dart';

/// The "Project" sidebar tab. Like [ForgePanel], detects the repo's forge,
/// then renders the shared [ProjectDashboardPanel] over the matching
/// dashboard provider. [forgeProvider] resolves [Forge.none] whenever
/// `git remote get-url origin` fails, so a dashboard is only ever attempted
/// with an origin present — no separate remote guard is needed here (the old
/// per-panel guard checked for remote-tracking *refs*, which wrongly blanked
/// the dashboard for a repo with an origin configured but never fetched).
class ForgeProjectPanel extends ConsumerWidget {
  final String repoPath;

  /// Whether this is the front (visible) sidebar page. No project shortcut
  /// exists today, but the flag keeps this panel's contract identical to the
  /// other five so any future panel-scoped behavior is gated from day one
  /// instead of silently running while offstage in the IndexedStack.
  final bool isActive;

  const ForgeProjectPanel({
    super.key,
    required this.repoPath,
    this.isActive = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forge = ref.watch(forgeProvider(repoPath));
    return forge.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => SectionError(err),
      data: (f) => switch (f) {
        Forge.github => ProjectDashboardPanel(
          dashboard: ref.watch(githubProjectDashboardProvider(repoPath)),
          onRefresh: () =>
              ref.invalidate(githubProjectDashboardProvider(repoPath)),
        ),
        Forge.gitlab => ProjectDashboardPanel(
          dashboard: ref.watch(projectDashboardProvider(repoPath)),
          onRefresh: () => ref.invalidate(projectDashboardProvider(repoPath)),
        ),
        Forge.none => const NoRemoteNotice('project features'),
        Forge.unknown => const UnsupportedForgeNotice(),
      },
    );
  }
}
