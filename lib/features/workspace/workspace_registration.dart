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

/// **Takes a [ProviderContainer], not a `WidgetRef`.** A `WidgetRef` in a sheet
/// re-resolves to whichever tab is active (`tabs_host.dart:500-505`), so a tab
/// switch during a create or clone would connect the finished repository into
/// the wrong tab's session — MADR 0038 F3. The caller is `WorkspaceFlow`, which
/// holds a container captured once and cannot drift.
///
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
  ProviderContainer ref, {
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
    await saveLocalRepo(ref, id: id, dest: dest, label: label);
  }
  return true;
}

/// The bookmark-and-save half of [registerAndActivateLocal], on its own so a
/// create that opens its result in **another** tab (MADR 0036, 3B) can
/// bookmark without connecting here. Returns the saved record, or null when
/// the store could not be written — the repository still exists either way.
///
/// The child of a picker-granted parent is bookmarkable while that grant is
/// live, which it is for the whole sheet. Unsigned builds return null from the
/// bookmark call → stored as '' (the local repo form's degraded path).
Future<SavedLocalRepo?> saveLocalRepo(
  ProviderContainer ref, {
  required String id,
  required String dest,
  String label = '',
}) async {
  final bookmark = await SecurityScopedBookmark.create(dest);
  final repo = SavedLocalRepo(
    id: id,
    label: label,
    repoPath: dest,
    bookmarkData: bookmark ?? '',
  );
  try {
    await ref.read(localRepoStoreProvider).save(repo);
    ref.invalidate(savedLocalReposProvider);
  } catch (_) {
    return null;
  }
  return repo;
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
