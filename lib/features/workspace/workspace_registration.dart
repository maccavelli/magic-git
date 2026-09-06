/// The clone and create sheets share one registration matrix — a new repo at
/// its destination must be persisted and become the active workspace the same
/// way no matter which sheet produced it. Kept as standalone functions (not
/// sheet methods) so there is exactly one implementation to reason about.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import 'workspace_targets.dart';

/// Opens [dest] as the active local session and (optionally) saves it to
/// Local Repositories with a security-scoped bookmark — the same sequence as
/// `AddExistingRepoSheet._openLocal`, minus the validation that `connectLocal`
/// performs. Best-effort on the save: the repo stays open for the session
/// even when persisting fails.
///
/// Returns whether [dest] actually became the live session — a silent false
/// used to let the sheets flash green Complete while the user was still on
/// the previous workspace (0009 H19). Save failures stay warnings (true).
Future<bool> registerAndActivateLocal(
  WidgetRef ref, {
  required String dest,
  String label = '',
  required bool save,
}) async {
  final id = save ? DateTime.now().microsecondsSinceEpoch.toString() : null;
  await ref
      .read(connectionProvider.notifier)
      .connectLocal(dest, label: label.isEmpty ? null : label, id: id);
  if (!ref.read(connectionProvider).isConnected) return false;
  if (id != null) {
    // Bookmark only a confirmed-open repo; the child of a picker-granted
    // parent is bookmarkable while that grant is live. Unsigned builds
    // return null → store '' (same degraded path as the local repo form).
    final bookmark = await SecurityScopedBookmark.create(dest);
    try {
      await ref
          .read(localRepoStoreProvider)
          .save(
            SavedLocalRepo(
              id: id,
              label: label,
              repoPath: dest,
              bookmarkData: bookmark ?? '',
            ),
          );
      ref.invalidate(savedLocalReposProvider);
    } catch (_) {
      // Open-for-session even if the save failed.
    }
  }
  return true;
}

/// Persists [dest] into the *active saved connection's* repo list (when the
/// session is a saved one — an ad-hoc session just switches), optionally
/// enables fsmonitor, and makes [dest] the active repo. Mirrors the
/// switcher's `_addRepo` + repo-switch sequence.
///
/// Returns whether the session ended on [dest] (see
/// [registerAndActivateLocal]) — false when the active session is gone.
Future<bool> registerAndActivateSshActive(
  WidgetRef ref, {
  required String dest,
  required bool fsmonitor,
  String label = '',
}) async {
  final connectionId = ref.read(connectionProvider).connectionId;
  if (connectionId != null) {
    SavedConnection? conn;
    try {
      final list = await ref.read(savedConnectionsProvider.future);
      for (final c in list) {
        if (c.id == connectionId) {
          conn = c;
          break;
        }
      }
    } catch (_) {
      // Store unreadable — fall through to session-only registration.
    }
    if (conn != null) {
      var updated = conn.copyWith(
        repoPaths: SavedConnection.dedupePaths([...conn.allRepoPaths, dest]),
      );
      if (label.isNotEmpty) updated = updated.withRepoLabel(dest, label);
      if (fsmonitor) updated = updated.withFsmonitor(dest, true);
      try {
        await ref.read(connectionStoreProvider).updateMetadata(updated);
        ref.invalidate(savedConnectionsProvider);
      } catch (_) {
        // Non-fatal: the repo still opens for this session.
      }
    }
  }
  if (fsmonitor) {
    try {
      await ref.read(gitServiceProvider).setFsmonitor(dest, enabled: true);
    } catch (_) {}
  }
  if (!ref.read(connectionProvider).isConnected) return false;
  ref.read(connectionProvider.notifier).setRepoPath(dest);
  return true;
}

/// The whole registration matrix in one place: dispatches [dest] to the right
/// activation for [target], and reports whether it actually became the live
/// workspace.
///
/// This `switch` was itself duplicated byte-for-byte in both sheets — the
/// shared functions above had one implementation while the code choosing
/// between them had two (MADR 0033). Everything the branches need is passed
/// in, so the function has no opinion about which sheet is calling: [connection]
/// resolves the chosen saved connection (the sheets get it from
/// `WorkspaceProvisioning.connectionById`), and [provisionToken] is that
/// mixin's adopted-session token.
Future<bool> registerAndActivate(
  WidgetRef ref, {
  required WorkspaceTarget target,
  required String dest,
  required String localLabel,
  required bool saveLocal,
  required String remoteLabel,
  required bool fsmonitor,
  required Future<SavedConnection?> Function() connection,
  required int? provisionToken,
}) async {
  switch (target) {
    case WorkspaceTarget.localMac:
      return registerAndActivateLocal(
        ref,
        dest: dest,
        label: localLabel,
        save: saveLocal,
      );
    case WorkspaceTarget.sshActive:
      return registerAndActivateSshActive(
        ref,
        dest: dest,
        fsmonitor: fsmonitor,
        label: remoteLabel,
      );
    case WorkspaceTarget.sshProvision:
      final conn = await connection();
      if (conn == null || provisionToken == null) return false;
      return ref
          .read(connectionProvider.notifier)
          .finalizeProvisioned(
            token: provisionToken,
            conn: conn,
            repoPath: dest,
            enableFsmonitor: fsmonitor,
            label: remoteLabel,
          );
  }
}
