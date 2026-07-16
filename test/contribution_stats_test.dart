import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/contribution_stats.dart';

void main() {
  // A fixed reference day so the grid layout is deterministic.
  // 2024-01-17 is a Wednesday.
  final today = DateTime(2024, 1, 17);

  group('computeContributionStats', () {
    test('empty history yields an all-zero grid', () {
      final s = computeContributionStats(const [], today: today, weeks: 4);
      expect(s.weeks, 4);
      expect(s.dayCount, 28);
      expect(s.countsByDay.every((c) => c == 0), isTrue);
      expect(s.maxCount, 0);
      expect(s.levelFor(0), 0);
      expect(s.levelFor(5), 0); // no max -> no level
    });

    test('grid starts on a Sunday and ends on/after today', () {
      final s = computeContributionStats(const [], today: today, weeks: 53);
      expect(s.start.weekday, DateTime.sunday);
      final lastDay = s.start.add(Duration(days: s.dayCount - 1));
      expect(!lastDay.isBefore(today), isTrue);
    });

    test('counts commits on their calendar day', () {
      final days = [
        DateTime(2024, 1, 17, 9), // today, three commits
        DateTime(2024, 1, 17, 13),
        DateTime(2024, 1, 17, 18),
        DateTime(2024, 1, 15, 10), // two days earlier
      ];
      final s = computeContributionStats(days, today: today, weeks: 53);
      final todayIdx = DateTime(2024, 1, 17).difference(s.start).inDays;
      final earlierIdx = DateTime(2024, 1, 15).difference(s.start).inDays;
      expect(s.countsByDay[todayIdx], 3);
      expect(s.countsByDay[earlierIdx], 1);
      expect(s.maxCount, 3);
    });

    test('ignores days outside the window', () {
      final days = [
        DateTime(2020, 5, 1), // way before the window
        DateTime(2024, 1, 17), // in window
        DateTime(2030, 1, 1), // future, past today
      ];
      final s = computeContributionStats(days, today: today, weeks: 8);
      expect(s.maxCount, 1);
      expect(s.countsByDay.fold<int>(0, (a, b) => a + b), 1);
    });

    test('relative levels bucket against the busiest day', () {
      final s = ContributionStats(
        start: DateTime(2024, 1, 1),
        weeks: 1,
        countsByDay: const [0, 1, 3, 5, 8, 10, 10],
        maxCount: 10,
      );
      expect(s.levelFor(0), 0);
      expect(s.levelFor(10), kContributionLevels); // busiest -> darkest
      expect(s.levelFor(1), 1); // smallest positive -> level 1
      // Every positive count maps into 1..kContributionLevels.
      for (final c in [1, 3, 5, 8, 10]) {
        final l = s.levelFor(c);
        expect(l >= 1 && l <= kContributionLevels, isTrue);
      }
    });

    test('dayAt/countAt agree with the flat index', () {
      final days = [DateTime(2024, 1, 16)]; // a Tuesday
      final s = computeContributionStats(days, today: today, weeks: 53);
      final idx = DateTime(2024, 1, 16).difference(s.start).inDays;
      final week = idx ~/ 7;
      final weekday = idx % 7;
      expect(s.countAt(week, weekday), 1);
      expect(s.dayAt(week, weekday), DateTime(2024, 1, 16));
    });
  });
}
