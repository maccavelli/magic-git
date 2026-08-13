import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import '../common/adaptive_workspace_layout.dart';
import '../common/repository_context.dart';
import '../common/repository_context_bar.dart';
import '../common/repository_workspace_scaffold.dart';
import '../common/workspace_focus.dart';
import '../common/workspace_navigation.dart';
import '../common/workspace_preferences_binding.dart';
import 'forge_selection.dart';

/// Shared repository chrome for GitHub and GitLab without introducing a forge
/// provider dependency. Everything in the context bar is connection state or
/// a value another visible surface has already landed.
class ForgeRepositoryWorkspace extends ConsumerWidget {
  final String repoPath;
  final String forgeLabel;
  final Widget? navigator;
  final Widget canvas;
  final ForgeSel selection;
  final String primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;

  const ForgeRepositoryWorkspace({
    super.key,
    required this.repoPath,
    required this.forgeLabel,
    this.navigator,
    required this.canvas,
    this.selection = const ForgeNothingSel(),
    this.primaryActionLabel = 'New Request',
    this.onPrimaryAction,
    this.loading = false,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    final pathParts = repoPath.split('/').where((part) => part.isNotEmpty);
    final supplementKey = connection.sessionEpoch <= 0
        ? null
        : RepositoryContextSupplementKey(
            repositoryIdentity: repositoryContextIdentityKey(
              backend: connection.backend.name,
              connectionId: connection.connectionId,
              repositoryPath: repoPath,
            ),
            sessionEpoch: connection.sessionEpoch,
          );
    final navigatorWidth = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.paneWidth(PaneId.forgeList),
      ),
    );
    final workspace = watchWorkspacePreferences(
      context: context,
      ref: ref,
      repositoryPath: repoPath,
      fallback: RepositoryWorkspacePrefs(navigatorWidth: navigatorWidth),
      preserveFallbackNavigatorWidth: true,
      onLegacyChanged: (next) {
        ref
            .read(appSettingsProvider.notifier)
            .setPaneWidth(PaneId.forgeList, next.navigatorWidth)
            .ignore();
      },
    );
    final snapshot = RepositoryContextSnapshot(
      repositoryPath: repoPath,
      repositoryName:
          'Repository: ${pathParts.isEmpty ? repoPath : pathParts.last}',
      connectionLabel: connection.connectionLabel,
      hostLabel: connection.isLocal ? 'On this Mac' : connection.host,
      branchLabel: forgeLabel,
      connected: connection.isConnected,
      supplement: supplementKey == null
          ? null
          : ref.watch(
              repositoryContextSupplementCacheProvider.select(
                (cache) => cache[supplementKey],
              ),
            ),
    );
    return RepositoryWorkspaceScaffold(
      repositoryContext: RepositoryContextBar(
        snapshot: snapshot,
        primaryAction: RepositoryPrimaryAction(
          kind: RepositoryPrimaryActionKind.publish,
          label: primaryActionLabel,
          disabledReason: onPrimaryAction == null
              ? '$forgeLabel action is unavailable'
              : null,
        ),
        onPrimaryAction: (_) => onPrimaryAction?.call(),
      ),
      navigator: navigator,
      canvas: canvas,
      loading: loading,
      error: error,
      onRetry: onRetry,
      activePage: selection is ForgeNothingSel
          ? CompactWorkspacePage.navigator
          : CompactWorkspacePage.canvas,
      preferences: workspace.preferences,
      onPreferencesChanged: workspace.onChanged,
      workspaceOptionsEnabled: true,
    );
  }
}

/// Publishes only a request or CI run the user selected from already-landed
/// list data. Issues, releases, labels, and create forms do not become passive
/// repository chrome and cannot accidentally widen its provider budget.
void publishLandedForgeSelection(
  WidgetRef ref, {
  required String repoPath,
  required String forgeLabel,
  required ForgeSel selection,
}) {
  final (kind, label, identity) = switch (selection) {
    ForgeChangeRequestSel(:final id) => (
      WorkspaceFocusKind.request,
      '$forgeLabel request #$id',
      '$id',
    ),
    ForgeCiRunSel(:final id) => (
      WorkspaceFocusKind.pipeline,
      '$forgeLabel CI run $id',
      '$id',
    ),
    _ => (null, null, null),
  };
  if (kind == null || label == null || identity == null) return;
  final connection = ref.read(connectionProvider);
  if (connection.sessionEpoch <= 0) return;
  final key = RepositoryContextSupplementKey(
    repositoryIdentity: repositoryContextIdentityKey(
      backend: connection.backend.name,
      connectionId: connection.connectionId,
      repositoryPath: repoPath,
    ),
    sessionEpoch: connection.sessionEpoch,
  );
  ref
      .read(repositoryContextSupplementCacheProvider.notifier)
      .publish(
        key,
        RepositoryContextSupplement(
          forgeLabel: forgeLabel,
          selectionLabel: label,
        ),
      );
  ref
      .read(
        workspaceNavigationProvider(
          WorkspaceSessionKey(repoPath, connection.sessionEpoch),
        ).notifier,
      )
      .visit(
        WorkspaceFocus(
          repositoryPath: repoPath,
          sessionEpoch: connection.sessionEpoch,
          kind: kind,
          identity: identity,
          panelIndex: 4,
        ),
      );
}
