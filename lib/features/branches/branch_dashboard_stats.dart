import '../../core/git/branch_review_query.dart';
import '../../core/git/git_service.dart';

/// The staleness policy lives in `branch_review_query.dart` (core) and is
/// re-exported so this file stays the single import Branches UI code needs.
/// It used to be duplicated verbatim in both places, which compiled only for
/// as long as no library imported both — the moment one did, the name became
/// an ambiguous import.
export '../../core/git/branch_review_query.dart'
    show kBranchStaleDays, isBranchStale;

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

/// Relative time for a unix epoch seconds field (creator/author date).
///
/// Pure and clock-injectable for tests. Empty string when [epochSeconds] is
/// null.
String relativeEpochLabel(int? epochSeconds, {DateTime? now}) {
  if (epochSeconds == null) return '';
  final then = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  final d = (now ?? DateTime.now()).difference(then);
  if (d.isNegative) return 'just now';
  if (d.inDays >= 365) {
    final y = (d.inDays / 365).floor();
    return '$y year${y == 1 ? '' : 's'} ago';
  }
  if (d.inDays >= 30) {
    final mo = (d.inDays / 30).floor();
    return '$mo month${mo == 1 ? '' : 's'} ago';
  }
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) {
    return '${d.inHours} hour${d.inHours == 1 ? '' : 's'} ago';
  }
  if (d.inMinutes >= 1) {
    return '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'} ago';
  }
  return 'just now';
}

/// Relative label for an ISO-8601 commit date string (History-style).
String relativeIsoLabel(String iso, {DateTime? now}) {
  final then = DateTime.tryParse(iso);
  if (then == null) return '';
  return relativeEpochLabel(
    then.millisecondsSinceEpoch ~/ 1000,
    now: now,
  );
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
