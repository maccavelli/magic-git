import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/branches/branch_dashboard_stats.dart';

void main() {
  final now = DateTime.utc(2026, 8, 4);

  GitRef local(
    String short, {
    bool isHead = false,
    int? creatorDate,
  }) {
    return GitRef(
      name: 'refs/heads/$short',
      oid: 'oid-$short',
      isHead: isHead,
      subject: short,
      creatorDate: creatorDate,
    );
  }

  group('isBranchStale', () {
    test('current HEAD is never stale', () {
      final head = local(
        'main',
        isHead: true,
        creatorDate: now.subtract(const Duration(days: 400)).millisecondsSinceEpoch ~/
            1000,
      );
      expect(isBranchStale(head, now: now), isFalse);
    });

    test('older than policy is stale', () {
      final old = local(
        'old',
        creatorDate:
            now.subtract(const Duration(days: 100)).millisecondsSinceEpoch ~/
                1000,
      );
      expect(isBranchStale(old, now: now), isTrue);
    });

    test('recent is not stale', () {
      final recent = local(
        'new',
        creatorDate:
            now.subtract(const Duration(days: 10)).millisecondsSinceEpoch ~/
                1000,
      );
      expect(isBranchStale(recent, now: now), isFalse);
    });
  });

  group('relativeEpochLabel', () {
    test('formats days', () {
      final epoch =
          now.subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000;
      expect(relativeEpochLabel(epoch, now: now), '3 days ago');
    });

    test('null is empty', () {
      expect(relativeEpochLabel(null, now: now), '');
    });
  });

  group('buildBranchDashboardStats', () {
    test('counts locals remotes tags and merged deletable', () {
      final refs = [
        local('main', isHead: true, creatorDate: now.millisecondsSinceEpoch ~/ 1000),
        local(
          'feature',
          creatorDate:
              now.subtract(const Duration(days: 5)).millisecondsSinceEpoch ~/
                  1000,
        ),
        local(
          'stale-one',
          creatorDate:
              now.subtract(const Duration(days: 120)).millisecondsSinceEpoch ~/
                  1000,
        ),
        local(
          'pinned-stale',
          creatorDate:
              now.subtract(const Duration(days: 200)).millisecondsSinceEpoch ~/
                  1000,
        ),
        const GitRef(
          name: 'refs/remotes/origin/main',
          oid: 'r1',
          isHead: false,
          subject: 'r',
        ),
        const GitRef(
          name: 'refs/tags/v1',
          oid: 't1',
          isHead: false,
          subject: 't',
        ),
      ];

      final stats = buildBranchDashboardStats(
        refs: refs,
        pinnedShortNames: {'pinned-stale'},
        mergedShortNames: {'feature', 'main'},
        now: now,
      );

      expect(stats.local, 4);
      expect(stats.remote, 1);
      expect(stats.tags, 1);
      expect(stats.pinned, 1);
      expect(stats.stale, 1); // stale-one only (pinned-stale counted as pinned)
      expect(stats.active, 2); // main + feature
      expect(stats.mergedDeletable, ['feature']); // not main (isHead)
    });

    test('filter narrows merged deletable but totals stay full local count', () {
      final refs = [
        local('main', isHead: true),
        local('feature-a'),
        local('other'),
      ];
      final stats = buildBranchDashboardStats(
        refs: refs,
        pinnedShortNames: const {},
        mergedShortNames: {'feature-a', 'other'},
        filterLower: 'feature',
        now: now,
      );
      // totalLocals is unfiltered count of local branches
      expect(stats.local, 3);
      expect(stats.mergedDeletable, ['feature-a']);
    });
  });

  group('branchNameMatchesFilter', () {
    test('empty matches all', () {
      expect(branchNameMatchesFilter(local('x'), ''), isTrue);
    });

    test('case insensitive substring', () {
      expect(branchNameMatchesFilter(local('Feature/Pay'), 'pay'), isTrue);
      expect(branchNameMatchesFilter(local('Feature/Pay'), 'zzz'), isFalse);
    });
  });
}
