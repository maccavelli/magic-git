/// Pinned (favorite) branches, persisted per repo in SharedPreferences under
/// `pinnedBranches_<repoPath>`. Deliberately self-contained (not folded into
/// [AppSettings]) and error-swallowing: a repo with none, or a platform with no
/// prefs (widget tests), resolves to an empty set with no error state — so the
/// Branches navigator never has to special-case it and no retry timer leaks.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _keyFor(String repoPath) => 'pinnedBranches_$repoPath';

/// The set of pinned branch short-names for [repoPath]. Empty on any error.
final pinnedBranchesProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, repoPath) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        return (prefs.getStringList(_keyFor(repoPath)) ?? const <String>[])
            .toSet();
      } catch (_) {
        return <String>{};
      }
    });

/// Pins or unpins [branch] for [repoPath] and refreshes
/// [pinnedBranchesProvider]. Best-effort persistence — a prefs failure still
/// invalidates so the UI reflects the intent for the session.
Future<void> setPinnedBranch(
  WidgetRef ref,
  String repoPath,
  String branch, {
  required bool pinned,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final key = _keyFor(repoPath);
    final set = (prefs.getStringList(key) ?? const <String>[]).toSet();
    if (pinned) {
      set.add(branch);
    } else {
      set.remove(branch);
    }
    if (set.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setStringList(key, set.toList());
    }
  } catch (_) {
    // Best-effort — still invalidate below so the session reflects the change.
  }
  ref.invalidate(pinnedBranchesProvider(repoPath));
}
