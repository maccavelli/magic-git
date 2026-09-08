import '../../core/git/branch_review_query.dart';
import '../../core/git/git_service.dart';

/// The staleness policy lives in `branch_review_query.dart` (core) and is
/// re-exported so this file stays the single import Branches UI code needs.
/// It used to be duplicated verbatim in both places, which compiled only for
/// as long as no library imported both — the moment one did, the name became
/// an ambiguous import.
export '../../core/git/branch_review_query.dart'
    show kBranchStaleDays, isBranchStale;

/// Relative-time labels moved to `core/utils/relative_time.dart` (MADR 0032
/// Phase 8), where a second feature could reach them, and are re-exported here
/// so Branches UI code keeps its single import — the same arrangement used for
/// the staleness policy above.
export '../../core/utils/relative_time.dart'
    show relativeEpochLabel, relativeIsoLabel;

/// Pure dashboard counts for the Branches empty-state (and later Review chips).
///
/// This is **not** a Browse/Review UI mode — it is the data shape formerly
/// private as `_ReviewSummary` in `branches_view.dart`.
class BranchDashboardStats {
  final int local;
  final int active;
  final int stale;
  final int pinned;
  final int remote;
  final int tags;

  /// Local short names merged into HEAD and not currently checked out — today's
  /// HEAD-relative bulk-cleanup set. Phase 1 removes bulk UX on this list;
  /// Phase 4 replaces it with base-relative OID-pinned cleanup.
  final List<String> mergedDeletable;

  const BranchDashboardStats({
    required this.local,
    required this.active,
    required this.stale,
    required this.pinned,
    required this.remote,
    required this.tags,
    required this.mergedDeletable,
  });
}

/// Substring filter on [GitRef.shortName] (case-insensitive). Empty filter
/// matches everything.
bool branchNameMatchesFilter(GitRef ref, String filterLower) {
  if (filterLower.isEmpty) return true;
  return ref.shortName.toLowerCase().contains(filterLower);
}

/// Build [BranchDashboardStats] from a refs snapshot and HEAD-merged short names.
///
/// [filterLower] is applied to short names the same way the navigator does.
/// [pinnedShortNames] are local short names in the pin set.
/// [mergedShortNames] is the HEAD-relative merged set (may be empty on error).
/// [hiddenShortNames] are local branches the user has hidden — excluded from
/// every count here too, or the dashboard would keep counting rows the
/// navigator no longer shows.
BranchDashboardStats buildBranchDashboardStats({
  required List<GitRef> refs,
  required Set<String> pinnedShortNames,
  required Set<String> mergedShortNames,
  Set<String> hiddenShortNames = const {},
  String filterLower = '',
  DateTime? now,
}) {
  bool visible(GitRef r) =>
      !r.isLocalBranch || !hiddenShortNames.contains(r.shortName);
  refs = [
    for (final r in refs)
      if (visible(r)) r,
  ];
  final totalLocals = refs.where((r) => r.isLocalBranch).length;
  final totalRemotes = refs.where((r) => r.isRemote).length;
  final allTags = refs.where((r) => r.isTag).toList();
  final locals = refs
      .where((r) => r.isLocalBranch && branchNameMatchesFilter(r, filterLower))
      .toList();

  var pinned = 0;
  var active = 0;
  var stale = 0;
  for (final b in locals) {
    if (pinnedShortNames.contains(b.shortName)) {
      pinned++;
    } else if (isBranchStale(b, now: now)) {
      stale++;
    } else {
      active++;
    }
  }

  final mergedDeletable = <String>[
    for (final b in locals)
      if (!b.isHead && mergedShortNames.contains(b.shortName)) b.shortName,
  ];

  return BranchDashboardStats(
    local: totalLocals,
    active: active,
    stale: stale,
    pinned: pinned,
    remote: totalRemotes,
    tags: allTags.length,
    mergedDeletable: mergedDeletable,
  );
}
