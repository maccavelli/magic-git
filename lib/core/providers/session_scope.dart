import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Process-unique identity of one **session container**.
///
/// Every tab is its own root [ProviderContainer] (`TabsController._create`), so
/// "the current session" is not a property of the process — there are up to
/// eight of them at once (`TabsController.maxTabs`), each with its own
/// `connectionProvider`, its own executor and its own live SSH client. Several
/// pieces of process-global state were written before that was true and still
/// read as though one session existed: they were reset, cleared or budgeted for
/// the whole process by whichever container happened to act last. This is the
/// key that gives each of them a per-session partition (MADR 0039, F1–F5).
///
/// What keys on it today:
///
///  * `KeepAliveLru` — the eleven diff/blame/log caches in `app_providers.dart`
///    are one set of objects for the process, so entries are keyed
///    `(scope, key)` and `clearHashKeyedRepoCaches` clears one scope. Without
///    it, any tab's connect released every other tab's cached patches, and two
///    tabs whose repo paths collided orphaned each other's `KeepAliveLink`s.
///  * `RepositoryUiIdentity.sessionScopeId` — ad-hoc (unsaved) workspace
///    preferences live in a process-global map, and `_attempt` (their previous
///    discriminator) is a *per-controller* counter, so two tabs' first ad-hoc
///    sessions both called themselves epoch 1.
///
/// `CommandTelemetry` has the same defect (MADR 0039 F5) and is **not** yet
/// partitioned — its singleton is still reset by whichever container connects
/// last. It is the next caller of this key, not a current one.
///
/// **A new process-global that describes "the current session" belongs here
/// too.** `test/session_scope_test.dart` and the per-subject isolation tests
/// (`session_cache_isolation_test.dart`, `session_prefs_isolation_test.dart`)
/// are what stop the next one shipping unpartitioned.
///
/// Deliberately opaque: an `int` with identity semantics and no meaning beyond
/// "not the same session as that other one". It is not an index, not a tab id,
/// and not stable across launches — nothing may persist it.
@immutable
class SessionScope {
  const SessionScope(this.id);

  /// Mints the next unused id. Called once per container, by
  /// [sessionScopeProvider].
  factory SessionScope.mint() => SessionScope(_next++);

  static int _next = 1;

  final int id;

  @override
  bool operator ==(Object other) => other is SessionScope && other.id == id;

  @override
  int get hashCode => id;

  @override
  String toString() => 'session#$id';
}

/// This container's [SessionScope].
///
/// A plain [Provider], **not** `autoDispose`: it is minted once per container
/// and must stay the same for that container's whole life, or the partitions it
/// keys would split mid-session and strand everything already filed under the
/// old id.
final sessionScopeProvider = Provider<SessionScope>(
  (ref) => SessionScope.mint(),
);
