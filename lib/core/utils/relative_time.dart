/// Human relative-time labels — "3 days ago", "just now".
///
/// Lives in `core/` because more than one feature needs it: Branches renders
/// it for commit and tag dates, and the create sheet's namespace suggestions
/// render it for forge activity. It was Branches-only until MADR 0032 Phase 8
/// needed the same wording, and a second copy would have drifted from this one
/// the first time either was corrected.
///
/// **House wording is the long form** — `3 days ago`, not `3d ago`. Every
/// existing surface says it that way, so a compact variant introduced for one
/// dropdown would read as a different app.
///
/// Pure and clock-injectable ([now]) so tests never depend on the wall clock.
library;

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
  return relativeEpochLabel(then.millisecondsSinceEpoch ~/ 1000, now: now);
}
