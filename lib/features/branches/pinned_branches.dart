/// Compatibility facade for identity-keyed Branches workspace preferences.
/// Saved/ad-hoc connections use one workspace-record writer; disconnected test
/// harnesses retain the old path-keyed fallback for source compatibility.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers/app_providers.dart';
import 'branch_workspace_prefs.dart';

String _keyFor(String repoPath) => 'pinnedBranches_$repoPath';

Future<Set<String>> _legacyPins(String repoPath) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_keyFor(repoPath)) ?? const <String>[]).toSet();
  } catch (_) {
    return <String>{};
  }
}

/// The set of pinned branch short-names for [repoPath]. Empty on any error.
final pinnedBranchesProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, repoPath) async {
      try {
        if (ref.watch(connectionProvider).sessionEpoch <= 0) {
          return _legacyPins(repoPath);
        }
        final prefs = await ref.watch(
          branchWorkspacePrefsProvider(repoPath).future,
        );
        return prefs.pinnedBranchNames.toSet();
      } catch (_) {
        return <String>{};
      }
    });

/// The set of hidden branch short-names for [repoPath]. Empty on any error.
///
/// Twin of [pinnedBranchesProvider] — same shape, same failure posture. There
/// is no legacy fallback because hiding never had a path-keyed predecessor.
final hiddenBranchesProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, repoPath) async {
      try {
        if (ref.watch(connectionProvider).sessionEpoch <= 0) {
          return <String>{};
        }
        final prefs = await ref.watch(
          branchWorkspacePrefsProvider(repoPath).future,
        );
        return prefs.hiddenBranchNames.toSet();
      } catch (_) {
        return <String>{};
      }
    });

/// Whether hidden branches are currently revealed for [repoPath].
final showHiddenBranchesProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, repoPath) async {
      try {
        if (ref.watch(connectionProvider).sessionEpoch <= 0) return false;
        final prefs = await ref.watch(
          branchWorkspacePrefsProvider(repoPath).future,
        );
        return prefs.showHidden;
      } catch (_) {
        return false;
      }
    });

/// Pins or unpins [branch] in the identity-keyed workspace record.
Future<void> setPinnedBranch(
  WidgetRef ref,
  String repoPath,
  String branch, {
  required bool pinned,
}) async {
  final connected = ref.read(connectionProvider).sessionEpoch > 0;
  final identity = connected
      ? await ref.read(repositoryUiIdentityProvider(repoPath).future)
      : null;
  if (identity != null) {
    try {
      await updateBranchWorkspacePrefs(
        identity: identity,
        legacyRepoPath: repoPath,
        globalCollapsed: await loadLegacyBranchCollapsedSections(),
        update: (current) {
          final pins = current.pinnedBranchNames.toSet();
          pinned ? pins.add(branch) : pins.remove(branch);
          return current.copyWith(pinnedBranchNames: pins.toList()..sort());
        },
      );
    } finally {
      ref.invalidate(branchWorkspacePrefsProvider(repoPath));
      ref.invalidate(pinnedBranchesProvider(repoPath));
    }
    return;
  }

  // Disconnected widget/test compatibility. A real Branches workspace has a
  // positive session epoch and therefore always takes the identity path above.
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
  ref.invalidate(branchWorkspacePrefsProvider(repoPath));
  ref.invalidate(pinnedBranchesProvider(repoPath));
}
