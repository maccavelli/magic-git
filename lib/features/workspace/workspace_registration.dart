/// Persisting and activating a **local** result, for `WorkspaceFlow.openResult`.
///
/// This file used to hold a three-branch registration "matrix" (MADR 0033).
/// MADR 0036 stopped producing one of its branches and nothing was removed, so
/// by MADR 0038 F6 the dispatcher had zero callers and the SSH-active branch
/// zero production callers while keeping four tests. Both are gone: the
/// dispatcher with the `_openResult` move (Phase 3), and the SSH-active branch
/// once its contract was ported onto `WorkspaceFlow._placeOnActiveSession`
/// (Phase 4), which is where the restored capability lives.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/providers/app_providers.dart';
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
/// the previous workspace (0009 H19).
///
/// **Opens without persisting, always.** It once took a `save` flag and
/// bookmarked the folder itself, but its only caller
/// (`WorkspaceFlow.openResult`) has always passed `save: false`: a result the
/// user *does* want saved goes through [saveLocalRepo] + `openLocalRepoInTab`
/// instead, so it lands in its own tab (MADR 0036, 3B). The flag was therefore
/// unreachable, and with it the second call to [saveLocalRepo] — two ways to
/// persist one thing, one of them dead. Removed 2026-09-08 (MADR 0038
/// residual).
Future<bool> registerAndActivateLocal(
  ProviderContainer ref, {
  required String dest,
  String label = '',
}) async {
  await ref
      .read(connectionProvider.notifier)
      .connectLocal(dest, label: label.isEmpty ? null : label);
  return ref.read(connectionProvider).isConnected;
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
