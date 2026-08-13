import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'async_write_queue.dart';
import 'saved_workspace_set.dart';
import 'store_bus.dart';

/// Persists named workspace sets and stable repository tab aliases.
///
/// Both records are additive SharedPreferences keys, so rollback can ignore
/// them without touching repositories, connections, credentials, or existing
/// pane preferences.
class SavedWorkspaceStore {
  static const setsStorageKey = 'saved_workspace_sets_v1';
  static const aliasesStorageKey = 'repository_tab_aliases_v1';

  final _setWrites = AsyncWriteQueue();
  final _aliasWrites = AsyncWriteQueue();

  Future<List<SavedWorkspaceSet>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(setsStorageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final sets = <SavedWorkspaceSet>[];
      for (final value in decoded) {
        if (value is! Map<String, dynamic>) continue;
        try {
          sets.add(SavedWorkspaceSet.fromJson(value));
        } catch (_) {
          // One malformed/future record must not hide the usable siblings.
        }
      }
      return sets;
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(SavedWorkspaceSet set) => _setWrites.run(() async {
    final normalized = set.normalized;
    final existing = await list();
    await _writeSets([
      ...existing.where((value) => value.id != normalized.id),
      normalized,
    ]);
  });

  Future<void> delete(String id) => _setWrites.run(() async {
    final existing = await list();
    await _writeSets(existing.where((value) => value.id != id).toList());
  });

  Future<void> _writeSets(List<SavedWorkspaceSet> sets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      setsStorageKey,
      jsonEncode([for (final set in sets) set.toJson()]),
    );
    StoreBus.instance.notifyWorkspaceSetsChanged();
  }

  Future<Map<SavedRepositoryIdentity, String>> aliases() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(aliasesStorageKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      final aliases = <SavedRepositoryIdentity, String>{};
      for (final value in decoded) {
        if (value is! Map<String, dynamic>) continue;
        try {
          final identity = SavedRepositoryIdentity.fromJson(value);
          final alias = (value['alias'] as String? ?? '').trim();
          if (alias.isNotEmpty) aliases[identity] = alias;
        } catch (_) {
          // Skip the malformed alias, preserving valid siblings.
        }
      }
      return aliases;
    } catch (_) {
      return const {};
    }
  }

  Future<void> setAlias(SavedRepositoryIdentity identity, String? alias) =>
      _aliasWrites.run(() async {
        final aliases = Map<SavedRepositoryIdentity, String>.of(
          await this.aliases(),
        );
        final normalized = alias?.trim() ?? '';
        if (normalized.isEmpty) {
          aliases.remove(identity);
        } else {
          aliases[identity] = normalized;
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          aliasesStorageKey,
          jsonEncode([
            for (final entry in aliases.entries)
              {...entry.key.toJson(), 'alias': entry.value},
          ]),
        );
      });
}
