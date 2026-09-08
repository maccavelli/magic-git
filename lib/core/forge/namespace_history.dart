/// Which forge namespaces this user has recently created into — the local half
/// of the create sheet's recency list (MADR 0032 Phase 3b).
///
/// **There are two stores, and this file is the only thing that knows it.**
///
///  * An **SSH target** hangs its history on the `SavedConnection`
///    (`namespaceHistory`, the parallel-map analogue of `repoLabels`). The
///    namespaces belong to that connection's forge account, so removing the
///    connection correctly takes them with it.
///  * A **This-Mac target** has no connection at all, and its forge account is
///    the Mac's *own* `gh`/`glab` login. Per-connection storage there is not
///    merely homeless — it is the wrong shape. Those live here, in
///    SharedPreferences, keyed the same way.
///  * An **ad-hoc SSH session** keeps session-only history: there is no record
///    to persist into, and inventing one would mean writing under a connection
///    the user deliberately chose not to save.
///
/// Two homes for one concept is a real cost — the split MADR 0033 spent five
/// phases undoing elsewhere — so the seam is kept honest: **one reader, one
/// writer**, both below, and callers never branch on the target themselves.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../forge/forge.dart';
import '../storage/connection_store.dart';
import '../storage/saved_connection.dart';

/// The key a namespace list is stored under. Forge **and** host, because a
/// namespace is meaningless across either — a GitLab group is not a GitHub
/// org, and two GitLab instances are different accounts.
String namespaceHistoryKey(Forge forge, String host) => '${forge.name}@$host';

/// Reads and records recently-used namespaces, choosing a store from the
/// target. The only place that knows there is more than one.
class NamespaceHistory {
  const NamespaceHistory(this._store);

  final ConnectionStore _store;

  static const _prefsPrefix = 'namespaceHistory_';

  /// Most-recent-first namespaces for this (forge, host).
  ///
  /// [connection] is the saved connection an SSH create targets; null means a
  /// This-Mac create (or an unsaved session), which reads the local store.
  Future<List<String>> recent({
    required Forge forge,
    required String host,
    SavedConnection? connection,
  }) async {
    final key = namespaceHistoryKey(forge, host);
    if (connection != null) return connection.namespacesFor(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList('$_prefsPrefix$key') ?? const [];
    } catch (_) {
      // History is a convenience; the field works with no list at all.
      return const [];
    }
  }

  /// Records [namespace] as the most recent use for this (forge, host).
  ///
  /// Best-effort by design: a create that succeeded must not be reported as
  /// failed because remembering it did not work.
  Future<void> record({
    required Forge forge,
    required String host,
    required String namespace,
    SavedConnection? connection,
  }) async {
    if (namespace.isEmpty) return;
    final key = namespaceHistoryKey(forge, host);
    if (connection != null) {
      try {
        await _store.updateMetadata(
          connection.withNamespaceUse(key, namespace),
        );
      } catch (_) {
        // Non-fatal: the repository was still created.
      }
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList('$_prefsPrefix$key') ?? const [];
      final next = <String>[
        namespace,
        ...existing.where((n) => n != namespace),
      ].take(SavedConnection.maxNamespaceHistory).toList();
      await prefs.setStringList('$_prefsPrefix$key', next);
    } catch (_) {
      // As above.
    }
  }
}
