import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local/scoped_access.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import '../../core/storage/saved_workspace_set.dart';
import '../connection/local_repo_form.dart';
import 'tabs_controller.dart';

class WorkspaceSetOpenFailure {
  final SavedWorkspaceRepositoryRef repository;
  final String reason;

  const WorkspaceSetOpenFailure(this.repository, this.reason);
}

class WorkspaceSetOpenReport {
  final int openedCount;
  final int focusedCount;
  final List<WorkspaceSetOpenFailure> failures;

  const WorkspaceSetOpenReport({
    required this.openedCount,
    required this.focusedCount,
    required this.failures,
  });

  bool get hasFailures => failures.isNotEmpty;
}

/// Opens every resolvable member of [set] in order through
/// [TabsController.openOrFocus]. Failures are isolated per member: successful
/// tabs stay open, duplicates focus their existing tab, and capacity/local
/// grant failures do not abort later deduped members.
Future<WorkspaceSetOpenReport> openSavedWorkspaceSet(
  BuildContext context,
  WidgetRef ref,
  SavedWorkspaceSet set,
) async {
  final tabs = TabsController.current;
  if (tabs == null) {
    return WorkspaceSetOpenReport(
      openedCount: 0,
      focusedCount: 0,
      failures: [
        for (final repository in set.repositories)
          WorkspaceSetOpenFailure(repository, 'Tabs are unavailable.'),
      ],
    );
  }

  var savedConnections = const <SavedConnection>[];
  var savedLocalRepos = const <SavedLocalRepo>[];
  try {
    savedConnections = await ref.read(connectionStoreProvider).list();
  } catch (_) {
    // An unavailable store is equivalent to every referenced SSH profile
    // being unavailable; each member below still receives its own failure.
  }
  try {
    savedLocalRepos = await ref.read(localRepoStoreProvider).list();
  } catch (_) {
    // Same per-member reporting behavior for local saved repositories.
  }
  final connections = {
    for (final connection in savedConnections) connection.id: connection,
  };
  final localRepos = {
    for (final repository in savedLocalRepos) repository.id: repository,
  };
  final openedByIndex = <int, RepoTab>{};
  final failures = <WorkspaceSetOpenFailure>[];
  final pending =
      <
        ({
          int index,
          SavedWorkspaceRepositoryRef repository,
          RepoTab tab,
          Future<void> operation,
        })
      >[];
  var opened = 0;
  var focused = 0;

  for (var index = 0; index < set.repositories.length; index++) {
    final repository = set.repositories[index];
    final existing = tabs.tabForIdentity(repository.identity);
    if (existing != null) {
      tabs.activate(existing.id);
      openedByIndex[index] = existing;
      focused++;
      await _applyMemberPresentation(tabs, existing, repository);
      continue;
    }
    if (!tabs.canOpenTab && !(tabs.active?.isBlank ?? false)) {
      failures.add(
        WorkspaceSetOpenFailure(
          repository,
          'Maximum of ${TabsController.maxTabs} tabs already open.',
        ),
      );
      continue;
    }

    switch (repository.kind) {
      case SavedRepositoryKind.ssh:
        final connection = connections[repository.savedId];
        if (connection == null ||
            !connection.allRepoPaths.contains(repository.repoPath)) {
          failures.add(
            WorkspaceSetOpenFailure(
              repository,
              'Saved SSH repository is no longer available.',
            ),
          );
          continue;
        }
        var didConnect = false;
        Future<void>? operation;
        final tab = tabs.openOrFocus(
          connectionId: connection.id,
          repoPath: repository.repoPath,
          savedKind: SavedRepositoryKind.ssh,
          connect: (container) {
            didConnect = true;
            operation = container
                .read(connectionProvider.notifier)
                .connectToSaved(connection, repoPath: repository.repoPath);
          },
        );
        if (!didConnect || operation == null) {
          failures.add(
            WorkspaceSetOpenFailure(repository, 'The tab limit was reached.'),
          );
          continue;
        }
        openedByIndex[index] = tab;
        pending.add((
          index: index,
          repository: repository,
          tab: tab,
          operation: operation!,
        ));
        await _applyMemberPresentation(tabs, tab, repository);

      case SavedRepositoryKind.local:
        final local = localRepos[repository.savedId];
        if (local == null || local.repoPath != repository.repoPath) {
          failures.add(
            WorkspaceSetOpenFailure(
              repository,
              'Saved local repository is no longer available.',
            ),
          );
          continue;
        }
        if (!context.mounted) {
          failures.add(
            WorkspaceSetOpenFailure(repository, 'Opening was cancelled.'),
          );
          continue;
        }
        final grants = await resolveSavedLocalRepo(context, local);
        if (grants == null) {
          failures.add(
            WorkspaceSetOpenFailure(
              repository,
              'Local repository access could not be restored.',
            ),
          );
          continue;
        }
        if (!context.mounted) {
          await _releaseGrants(grants);
          failures.add(
            WorkspaceSetOpenFailure(repository, 'Opening was cancelled.'),
          );
          continue;
        }
        var didConnect = false;
        Future<void>? operation;
        final tab = tabs.openOrFocus(
          connectionId: local.id,
          repoPath: grants.repoPath,
          savedKind: SavedRepositoryKind.local,
          savedReferencePath: repository.repoPath,
          connect: (container) {
            didConnect = true;
            operation = container
                .read(connectionProvider.notifier)
                .connectLocal(
                  grants.repoPath,
                  label: local.label.isEmpty ? null : local.label,
                  id: local.id,
                  mainRepoPath: grants.mainRepoPath,
                  gitDir: local.isScoped ? local.gitDir : null,
                );
          },
        );
        if (!didConnect || operation == null) {
          await _releaseGrants(grants);
          failures.add(
            WorkspaceSetOpenFailure(repository, 'The tab limit was reached.'),
          );
          continue;
        }
        openedByIndex[index] = tab;
        pending.add((
          index: index,
          repository: repository,
          tab: tab,
          operation: operation!,
        ));
        await _applyMemberPresentation(tabs, tab, repository);
    }
  }

  await Future.wait([
    for (final item in pending)
      () async {
        try {
          await item.operation;
        } catch (error) {
          failures.add(
            WorkspaceSetOpenFailure(item.repository, error.toString()),
          );
          openedByIndex.remove(item.index);
          return;
        }
        final state = item.tab.container.read(connectionProvider);
        if (state.isConnected) {
          opened++;
          return;
        }
        failures.add(
          WorkspaceSetOpenFailure(
            item.repository,
            state.error ?? 'Repository could not be opened.',
          ),
        );
        openedByIndex.remove(item.index);
      }(),
  ]);

  final preferred = openedByIndex[set.normalized.activeIndex];
  if (preferred != null) {
    tabs.activate(preferred.id);
  } else if (openedByIndex.isNotEmpty) {
    tabs.activate(openedByIndex.values.last.id);
  }
  return WorkspaceSetOpenReport(
    openedCount: opened,
    focusedCount: focused,
    failures: failures,
  );
}

Future<void> _releaseGrants(LocalOpenGrants grants) async {
  await ScopedAccess.instance.release(grants.repoPath);
  final main = grants.mainRepoPath;
  if (main != null) await ScopedAccess.instance.release(main);
}

Future<void> _applyMemberPresentation(
  TabsController tabs,
  RepoTab tab,
  SavedWorkspaceRepositoryRef repository,
) async {
  if (repository.tabAlias != null) {
    try {
      await tabs.setAliasForReference(repository.identity, repository.tabAlias);
    } catch (_) {
      // Alias persistence is optional presentation state; it must not turn a
      // successfully opened repository into a workspace-member failure.
    }
  }
  final preset = WorkspacePreset.values
      .where((value) => value.name == repository.layoutPresetName)
      .firstOrNull;
  if (preset == null) return;
  _applyPresetWhenConnected(tab, tab.repoPath ?? repository.repoPath, preset);
}

void _applyPresetWhenConnected(
  RepoTab tab,
  String repoPath,
  WorkspacePreset preset,
) {
  Future<void> apply() async {
    try {
      final container = tab.container;
      final identity = await container.read(
        repositoryUiIdentityProvider(repoPath).future,
      );
      if (identity == null) return;
      await updateRepositoryWorkspacePrefs(
        identity: identity,
        update: (current) => applyWorkspacePreset(current, preset),
      );
      container.invalidate(repositoryWorkspacePrefsProvider(repoPath));
    } catch (_) {
      // Layout restoration is optional presentation state. The connected tab
      // remains usable if identity or preference storage cannot be resolved.
    }
  }

  final connection = tab.container.read(connectionProvider);
  if (connection.isConnected) {
    unawaited(apply());
    return;
  }
  late final ProviderSubscription<ConnectionState> subscription;
  subscription = tab.container.listen(connectionProvider, (_, next) {
    if (next.isConnected) {
      subscription.close();
      unawaited(apply());
    } else if (next.phase == ConnectionPhase.error ||
        next.phase == ConnectionPhase.disconnected) {
      subscription.close();
    }
  });
}
