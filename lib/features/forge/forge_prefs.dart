import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The Forge list-section collapse store moved to the canonical, app-wide
// `collapsedSectionsProvider` in `../common/section_collapse.dart` so the
// Forge and Branches tabs share one minimize/expand mechanism.

/// A branch destined for the Forge create-PR/MR form: the mounted forge panel
/// for [repoPath] opens its inline form seeded with [branch] (and optional
/// [baseRef] forge branch name), then clears this. A provider (not a
/// constructor argument) because drop handlers and Branches live outside the
/// panel's widget tree.
typedef ForgeCreateSeedData = ({
  String repoPath,
  String branch,
  String? baseRef,
});

class ForgeCreateSeed extends Notifier<ForgeCreateSeedData?> {
  @override
  ForgeCreateSeedData? build() => null;

  /// [baseRef] is a forge branch name (`main`), never `origin/main`.
  void set(String repoPath, String branch, {String? baseRef}) =>
      state = (repoPath: repoPath, branch: branch, baseRef: baseRef);

  void clear() => state = null;
}

final forgeCreateSeedProvider =
    NotifierProvider<ForgeCreateSeed, ForgeCreateSeedData?>(
      ForgeCreateSeed.new,
    );

/// History handoff from Branches (and similar): main History mount consumes
/// once into a visible revision scope, then clears. Parallel to forge seed.
typedef HistoryNavigationIntent = ({String repoPath, String revision});

class HistoryNavigationIntentNotifier
    extends Notifier<HistoryNavigationIntent?> {
  @override
  HistoryNavigationIntent? build() => null;

  void set(String repoPath, String revision) =>
      state = (repoPath: repoPath, revision: revision);

  void clear() => state = null;
}

final historyNavigationIntentProvider =
    NotifierProvider<HistoryNavigationIntentNotifier, HistoryNavigationIntent?>(
      HistoryNavigationIntentNotifier.new,
    );

/// Whether the Forge list column shows the Inbox (unified triage list) or
/// Browse (the full sections). Inbox is the default view; the choice is
/// global and persisted.
class ForgeInboxMode extends Notifier<bool> {
  static const _key = 'forgeInboxMode';

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(_key);
      if (stored != null) state = stored;
    } catch (_) {}
  }

  Future<void> set(bool inbox) async {
    state = inbox;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, inbox);
    } catch (_) {}
  }
}

final forgeInboxModeProvider = NotifierProvider<ForgeInboxMode, bool>(
  ForgeInboxMode.new,
);

/// A repo's pinned and snoozed inbox items, by item key (`mr:7`, `ci:100`,
/// `issue:12`). Pinned floats to the top of the Inbox; snoozed sinks to its
/// own group at the bottom. Persisted per repo as a string list with `p:` /
/// `s:` prefixes.
class ForgeInboxMarks
    extends Notifier<({Set<String> pinned, Set<String> snoozed})> {
  ForgeInboxMarks(this.repoPath);
  final String repoPath;

  String get _key => 'forgeInboxMarks_$repoPath';

  @override
  ({Set<String> pinned, Set<String> snoozed}) build() {
    _load();
    return (pinned: const {}, snoozed: const {});
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_key);
      if (stored == null || stored.isEmpty) return;
      state = (
        pinned: {
          for (final e in stored)
            if (e.startsWith('p:')) e.substring(2),
        },
        snoozed: {
          for (final e in stored)
            if (e.startsWith('s:')) e.substring(2),
        },
      );
    } catch (_) {}
  }

  Future<void> togglePin(String itemKey) => _toggle(itemKey, pin: true);

  Future<void> toggleSnooze(String itemKey) => _toggle(itemKey, pin: false);

  Future<void> _toggle(String itemKey, {required bool pin}) async {
    final pinned = Set<String>.from(state.pinned);
    final snoozed = Set<String>.from(state.snoozed);
    final target = pin ? pinned : snoozed;
    final other = pin ? snoozed : pinned;
    // Pin and snooze are mutually exclusive: marking one clears the other.
    if (target.contains(itemKey)) {
      target.remove(itemKey);
    } else {
      target.add(itemKey);
      other.remove(itemKey);
    }
    state = (pinned: pinned, snoozed: snoozed);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, [
        for (final k in pinned.toList()..sort()) 'p:$k',
        for (final k in snoozed.toList()..sort()) 's:$k',
      ]);
    } catch (_) {}
  }
}

final forgeInboxMarksProvider = NotifierProvider.autoDispose
    .family<
      ForgeInboxMarks,
      ({Set<String> pinned, Set<String> snoozed}),
      String
    >(ForgeInboxMarks.new);
