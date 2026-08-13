import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/settings/repository_workspace_prefs.dart';

typedef WorkspacePreferencesBinding = ({
  RepositoryWorkspacePrefs preferences,
  ValueChanged<RepositoryWorkspacePrefs>? onChanged,
});

/// Connects a migrated screen to the repository-scoped workspace record.
///
/// [fallback] keeps first paint synchronous while identity resolution runs.
/// [onLegacyChanged] may mirror width changes into the old global pane key so
/// that rolling back the workspace does not discard a user's latest sizing.
WorkspacePreferencesBinding watchWorkspacePreferences({
  required BuildContext context,
  required WidgetRef ref,
  required String repositoryPath,
  RepositoryWorkspacePrefs fallback = const RepositoryWorkspacePrefs(),
  ValueChanged<RepositoryWorkspacePrefs>? onLegacyChanged,
  bool preserveFallbackNavigatorWidth = false,
}) {
  final identity = ref
      .watch(repositoryUiIdentityProvider(repositoryPath))
      .value;
  final loaded = ref
      .watch(repositoryWorkspacePrefsProvider(repositoryPath))
      .value;
  // Disconnected/widget-test sessions have no repository identity. Keep the
  // screen's legacy geometry instead of replacing it with a generic default
  // when the asynchronous workspace provider settles.
  final resolved = identity == null ? fallback : loaded ?? fallback;
  final preferences = preserveFallbackNavigatorWidth
      ? resolved.copyWith(navigatorWidth: fallback.navigatorWidth)
      : resolved;
  final ValueChanged<RepositoryWorkspacePrefs>? onChanged = identity == null
      ? onLegacyChanged
      : (next) {
          onLegacyChanged?.call(next);
          final persisted = preserveFallbackNavigatorWidth
              ? next.copyWith(navigatorWidth: resolved.navigatorWidth)
              : next;
          unawaited(
            saveRepositoryWorkspacePrefs(
              identity: identity,
              next: persisted,
            ).then((_) {
              if (context.mounted) {
                ref.invalidate(
                  repositoryWorkspacePrefsProvider(repositoryPath),
                );
              }
            }),
          );
        };
  return (preferences: preferences, onChanged: onChanged);
}
