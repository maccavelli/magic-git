/// Where a repository goes once it exists: its own tab (MADR 0036, 3B).
///
/// **Nothing here is new.** Each function is a production path that used to
/// live at its only call site, moved so the create and clone sheets can call
/// one thing and the connection switcher keeps calling the same code — the
/// reason MADR 0033 gives for every other shared piece of these sheets:
///
///  * [openSshRepoInTab] — the switcher's open (`connection_switcher.dart`).
///  * [openLocalRepoInTab] — the switcher's local open **with its grant-release
///    guard**, which is the one part of this file that touches the sandbox.
///  * [finalizeProvisionedInTab] — the registration matrix's `sshProvision`
///    branch, run against the tab that dialled rather than the sheet's own
///    container.
library;

import '../../core/local/scoped_access.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import '../../core/storage/saved_workspace_set.dart';
import '../connection/local_repo_form.dart' show LocalOpenGrants;
import '../tabs/tabs_controller.dart';

/// Opens [conn]'s [repoPath] in its own tab, dialling a fresh session there.
/// A matching open tab is focused instead (`openOrFocus`'s dedupe).
RepoTab openSshRepoInTab({
  required TabsController tabs,
  required SavedConnection conn,
  required String repoPath,
}) => tabs.openOrFocus(
  connectionId: conn.id,
  repoPath: repoPath,
  savedKind: SavedRepositoryKind.ssh,
  connect: (container) => container
      .read(connectionProvider.notifier)
      .connectToSaved(conn, repoPath: repoPath),
);

/// Opens saved local [repo] in its own tab, given [grants] the caller has
/// already resolved (its bookmark acquired; a linked worktree's main repo
/// granted). Returns the tab, or null when no session started.
///
/// **If no session started, every grant is released.** `openOrFocus` declines
/// at the tab cap and never runs `connect`, and a racing double-open can
/// focus a tab whose own `connect` ran elsewhere. Either way the access
/// acquired for [grants] backs nothing and would leak for the app's lifetime
/// — a linked worktree acquired two. [scopedAccess] is the registry those
/// grants were taken from; tests pass a counting one.
Future<RepoTab?> openLocalRepoInTab({
  required TabsController tabs,
  required SavedLocalRepo repo,
  required LocalOpenGrants grants,
  ScopedAccess? scopedAccess,
}) async {
  final access = scopedAccess ?? ScopedAccess.instance;
  final label = repo.label.isEmpty ? null : repo.label;
  var connected = false;
  final tab = tabs.openOrFocus(
    connectionId: repo.id,
    repoPath: grants.repoPath,
    savedKind: SavedRepositoryKind.local,
    savedReferencePath: repo.repoPath,
    connect: (container) {
      connected = true;
      container
          .read(connectionProvider.notifier)
          .connectLocal(
            grants.repoPath,
            label: label,
            id: repo.id,
            mainRepoPath: grants.mainRepoPath,
            gitDir: repo.isScoped ? repo.gitDir : null,
          );
    },
  );
  if (connected) return tab;
  await access.release(grants.repoPath);
  final main = grants.mainRepoPath;
  if (main != null) await access.release(main);
  return null;
}

/// Promotes the session dialled in [tab] into a workspace on [dest]. Returns
/// whether it became the live workspace; on false the caller closes [tab],
/// because a tab that exists only after submit has exactly one owner
/// (MADR 0036, 6B).
Future<bool> finalizeProvisionedInTab({
  required RepoTab tab,
  required SavedConnection conn,
  required int token,
  required String dest,
  bool fsmonitor = false,
  String label = '',
}) => tab.container
    .read(connectionProvider.notifier)
    .finalizeProvisioned(
      token: token,
      conn: conn,
      repoPath: dest,
      enableFsmonitor: fsmonitor,
      label: label,
    );
