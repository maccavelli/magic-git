/// Per-day commit-activity aggregation for a GitHub-style contribution heatmap.
///
/// Pure and deterministic (the reference "today" is passed in, never read from
/// the clock) so it unit-tests cleanly and can run off the UI isolate. The
/// shading is **relative** (GitHub-style): the busiest day sets the top of the
/// scale and every other day is bucketed against it, so the map reads the same
/// regardless of a repo's absolute commit volume. Streaks are deliberately not
/// computed — the map shows the work, not a duration to defend.
library;

/// The number of intensity levels above zero (matching GitHub's four greens).
const int kContributionLevels = 4;

/// A laid-out contribution grid: [weeks] columns of 7 days, oldest week first,
/// each column running Sunday→Saturday.
class ContributionStats {
  /// The Sunday that starts the first (oldest) column.
  final DateTime start;

  /// Number of week columns.
  final int weeks;

  /// Daily commit counts, indexed `week * 7 + weekday` where weekday 0 = Sunday.
  /// Days outside the requested window (before [start] or after the reference
  /// day) are 0.
  final List<int> countsByDay;

  /// The highest single-day count in the window (0 when there is no activity).
  final int maxCount;

  const ContributionStats({
    required this.start,
    required this.weeks,
    required this.countsByDay,
    required this.maxCount,
  });

  /// Total days in the grid (`weeks * 7`).
  int get dayCount => weeks * 7;

  /// Count for the cell at [week] (0-based, oldest first) and [weekday]
  /// (0 = Sunday … 6 = Saturday).
  int countAt(int week, int weekday) => countsByDay[week * 7 + weekday];

  /// The calendar day for the cell at [week]/[weekday].
  DateTime dayAt(int week, int weekday) =>
      start.add(Duration(days: week * 7 + weekday));

  /// Relative intensity level 0..[kContributionLevels] for [count]: 0 for no
  /// activity, otherwise bucketed against [maxCount] so the busiest day is the
  /// darkest.
  int levelFor(int count) {
    if (count <= 0 || maxCount <= 0) return 0;
    final level = (count * kContributionLevels + maxCount - 1) ~/ maxCount;
    return level > kContributionLevels ? kContributionLevels : level;
  }
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Aggregates [commitDays] into a [ContributionStats] grid ending on the week
/// containing [today] and spanning [weeks] columns (default 53 ≈ one year).
///
/// [commitDays] may contain any `DateTime`s (commit author dates); only their
/// calendar day is used, and days outside the window are ignored.
ContributionStats computeContributionStats(
  Iterable<DateTime> commitDays, {
  required DateTime today,
  int weeks = 53,
}) {
  final todayDay = _dayOnly(today);
  // The grid's last column is the week containing today; walk back to its
  // Sunday, then back (weeks-1) more weeks to the first column's Sunday.
  final endSunday = todayDay.subtract(Duration(days: todayDay.weekday % 7));
  final start = endSunday.subtract(Duration(days: (weeks - 1) * 7));
  final lastIndex = todayDay.difference(start).inDays; // inclusive upper bound

  final counts = List<int>.filled(weeks * 7, 0);
  var maxCount = 0;
  for (final raw in commitDays) {
    final day = _dayOnly(raw);
    final idx = day.difference(start).inDays;
    if (idx < 0 || idx >= counts.length || idx > lastIndex) continue;
    final next = counts[idx] + 1;
    counts[idx] = next;
    if (next > maxCount) maxCount = next;
  }

  return ContributionStats(
    start: start,
    weeks: weeks,
    countsByDay: counts,
    maxCount: maxCount,
  );
}
