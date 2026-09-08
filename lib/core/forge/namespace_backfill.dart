/// The retroactive half of MADR 0037: learn namespaces from the repositories
/// already in the recents list, so the create sheet's recency is useful on the
/// first run rather than only after the next open of each repo.
///
/// **Nothing here dials.** The scan runs while the create sheet is opening
/// (Phase 4), so it reads only what is available *without a handshake* — the
/// MADR's option 1D:
///
///  * a saved **local** repo, whose security-scoped bookmark resolves silently
///    and whose `LocalCommandExecutor` needs no session at all;
///  * an **SSH** repo whose host already has a live session in some tab, read
///    through *that tab's* `GitService`.
///
/// A saved SSH host with no live session is **skipped, never dialled**. That is
/// the MADR's central limit and it is deliberate: a handshake here would make
/// the wizard wait on the network for a suggestion list. Those hosts are
/// covered by the other half — `ConnectionController` records the namespace at
/// the next open.
///
/// Idempotent by construction: `NamespaceHistory` de-duplicates and bounds, so
/// there is no "already backfilled" flag to keep in sync, and a repository
/// whose origin has since moved self-heals on the next scan.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tabs/tabs_controller.dart';
import '../git/git_service.dart';
import '../local/scoped_access.dart';
import '../providers/app_providers.dart';
import '../storage/recent_repos_store.dart';
import '../storage/saved_local_repo.dart';

/// Reads the origin of every recent repository that can be reached without a
/// handshake and records its namespace (MADR 0037 Phase 3).
///
/// Best-effort throughout, like the recording it feeds: one unreadable
/// repository never stops the rest, and the whole scan failing is invisible to
/// the caller. Pass [access] to inject the security-scoped registry in tests;
/// production uses the shared [ScopedAccess.instance] every session shares, so
/// a folder a live tab already holds is not revoked out from under it.
Future<void> backfillNamespacesFromRecents(
  ProviderContainer container, {
  ScopedAccess? access,
}) async {
  final grants = access ?? ScopedAccess.instance;
  final List<RecentRepoRef> recents;
  try {
    recents = await container.read(recentRepoRefsProvider.future);
  } catch (_) {
    return;
  }
  if (recents.isEmpty) return;

  final localById = <String, SavedLocalRepo>{};
  if (recents.any((r) => r.isLocal)) {
    try {
      for (final repo in await container.read(savedLocalReposProvider.future)) {
        localById[repo.id] = repo;
      }
    } catch (_) {
      // The local store is unreadable; the SSH half still applies.
    }
  }

  for (final recent in recents) {
    try {
      final url = recent.isLocal
          ? await _localOriginUrl(container, localById[recent.id], grants)
          : await _sshOriginUrl(recent);
      if (url == null || url.isEmpty) continue;
      await container
          .read(connectionProvider.notifier)
          .recordNamespaceFromOrigin(
            url: url,
            isLocal: recent.isLocal,
            connectionId: recent.id,
            // The open this namespace is evidence of, not the moment the scan
            // happened — otherwise a backfill would rank every stale repo
            // above one genuinely opened yesterday.
            at: recent.openedAt,
          );
    } on StateError {
      // Reading a disposed [ProviderContainer] throws this, and the container
      // is disposed when the tab holding the sheet closes. Abandon the scan
      // rather than grinding through the remaining refs throwing on each: it
      // is idempotent, so the next mount simply starts again.
      //
      // Riverpod marks `ProviderContainer.disposed` `@internal`, so this is
      // the only supported way to notice.
      return;
    } catch (_) {
      // One repository that will not read is not a reason to abandon the rest.
    }
  }
}

/// The origin of a saved local repo, read offline under its bookmark grants.
///
/// Returns null for a repo that is no longer saved, has no bookmark, or whose
/// bookmark no longer resolves (a moved or deleted folder) — none of which is
/// an error worth surfacing from a background scan.
Future<String?> _localOriginUrl(
  ProviderContainer container,
  SavedLocalRepo? repo,
  ScopedAccess grants,
) async {
  if (repo == null || repo.bookmarkData.isEmpty) return null;
  // A GUI-launched app's inherited PATH usually lacks the dir `git` lives in;
  // the create/clone sheets already lean on this guard for the same reason.
  await container.read(localEnvironmentProvider).ensure();

  final held = <String>[];
  try {
    final path = await grants.acquire(repo.bookmarkData);
    if (path == null) return null; // Stale bookmark — skip, do not re-prompt.
    held.add(path);
    // A linked worktree reads its main repository's `.git` too, so a single
    // grant is not enough to run even `git remote get-url` in it.
    if (repo.mainRepoBookmarkData.isNotEmpty) {
      final main = await grants.acquire(repo.mainRepoBookmarkData);
      if (main != null) held.add(main);
    }
    final git = GitService(container.read(localExecutorProvider));
    if (repo.gitDir.isNotEmpty) {
      // A scoped work tree (the dotfiles pattern) has no `.git` to discover, so
      // without this the read fails with "not a git repository".
      git.registerRepoScope(path, gitDir: repo.gitDir, workTree: path);
    }
    return await git.originUrl(path);
  } finally {
    // Released even when the read throws: a leaked refcount here would keep a
    // native grant alive for the life of the process.
    for (final path in held) {
      await grants.release(path);
    }
  }
}

/// The origin of an SSH repo, read through the tab that already holds a live
/// session on its connection. Null — never a dial — when no tab does.
Future<String?> _sshOriginUrl(RecentRepoRef recent) async {
  final tabs = TabsController.current;
  if (tabs == null) return null;
  for (final tab in tabs.tabs) {
    final state = tab.container.read(connectionProvider);
    if (!state.isConnected || state.isLocal) continue;
    if (state.connectionId != recent.id) continue;
    // That tab's GitService, not this one's: it is the one holding the session,
    // and the one carrying any git-dir scopes the connection registered.
    return tab.container.read(gitServiceProvider).originUrl(recent.repoPath);
  }
  return null;
}
