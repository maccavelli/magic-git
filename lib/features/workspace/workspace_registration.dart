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

/// Opens [dest] as the active local session and (optionally) saves it to
/// Local Repositories with a security-scoped bookmark — the same sequence as
/// `NewLocalRepoSheet._open`, minus the validation that `connectLocal` itself
/// performs. Best-effort on the save: the repo stays open for the session
/// even when persisting fails.
Future<void> registerAndActivateLocal(
  WidgetRef ref, {
  required String dest,
  String label = '',
  required bool save,
}) async {
  final id = save ? DateTime.now().microsecondsSinceEpoch.toString() : null;
  await ref
      .read(connectionProvider.notifier)
      .connectLocal(dest, label: label.isEmpty ? null : label, id: id);
  if (!ref.read(connectionProvider).isConnected) return;
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
}

/// Persists [dest] into the *active saved connection's* repo list (when the
/// session is a saved one — an ad-hoc session just switches), optionally
/// enables fsmonitor, and makes [dest] the active repo. Mirrors the
/// switcher's `_addRepo` + repo-switch sequence.
Future<void> registerAndActivateSshActive(
  WidgetRef ref, {
  required String dest,
  required bool fsmonitor,
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
  ref.read(connectionProvider.notifier).setRepoPath(dest);
}
