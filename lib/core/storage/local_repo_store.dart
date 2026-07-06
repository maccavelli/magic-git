import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'async_write_queue.dart';
import 'saved_local_repo.dart';

/// Persists bookmarked local repos — non-secret metadata only; a local repo
/// has no credentials, so unlike [ConnectionStore] there is no Keychain/
/// dotfile secret path at all. Mirrors [ConnectionStore]'s persistence
/// conventions (corrupt-blob-degrades-to-empty, per-entry skip, serialized
/// read-modify-write) against its own storage key, so SSH connection storage
/// is completely unaffected.
class LocalRepoStore {
  static const _metaKey = 'saved_local_repos';

  /// Serializes every read-modify-write against the metadata blob — without
  /// this, two calls in-flight at once (e.g. a `touch` on open racing a
  /// `save` from the new-repo sheet) interleave their read and write, and
  /// whichever writes last silently clobbers the other's change. Same
  /// reasoning as [ConnectionStore._writes].
  final _writes = AsyncWriteQueue();

  Future<List<SavedLocalRepo>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_metaKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <SavedLocalRepo>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        try {
          out.add(SavedLocalRepo.fromJson(item));
        } catch (_) {
          // Skip a single malformed entry rather than losing the whole list.
        }
      }
      return out;
    } catch (_) {
      // A corrupt/truncated blob must not throw: list() is read by the
      // switcher panel and called inside every save/touch/delete. Degrade to
      // empty rather than breaking the local-repos UI wholesale.
      return [];
    }
  }

  /// Persists the full local-repo list as the metadata blob. The single
  /// writer used by [save]/[touch]/[delete].
  Future<void> _writeMetadata(List<SavedLocalRepo> repos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _metaKey,
      jsonEncode(repos.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> save(SavedLocalRepo repo) => _writes.run(() async {
    final existing = await list();
    await _writeMetadata([...existing.where((r) => r.id != repo.id), repo]);
  });

  /// Alias for [save] — a local repo has no secrets, so unlike
  /// [ConnectionStore] there's no separate "metadata vs secrets" distinction.
  /// Kept as its own name so UI code updating just the repo list/fsmonitor
  /// flag reads the same as the SSH connections panel's equivalent call.
  Future<void> updateMetadata(SavedLocalRepo repo) => save(repo);

  /// Stamps a repo's `lastConnectedAt` with [when] (defaults to now) so it
  /// floats to the top of any recency ordering. Best-effort no-op if the id
  /// isn't found.
  Future<void> touch(String id, {DateTime? when}) => _writes.run(() async {
    final existing = await list();
    final idx = existing.indexWhere((r) => r.id == id);
    if (idx < 0) return;
    final updated = existing[idx].copyWith(
      lastConnectedAt: when ?? DateTime.now(),
    );
    await _writeMetadata([...existing.where((r) => r.id != id), updated]);
  });

  Future<void> delete(String id) => _writes.run(() async {
    final existing = await list();
    await _writeMetadata(existing.where((r) => r.id != id).toList());
  });
}
