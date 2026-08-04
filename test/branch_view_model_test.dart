import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/branches/branch_view_model.dart';

void main() {
  final now = DateTime.utc(2026, 8, 4);

  GitRef local(
    String short, {
    bool isHead = false,
    int? creatorDate,
  }) =>
      GitRef(
        name: 'refs/heads/$short',
        oid: 'o-$short',
        isHead: isHead,
        subject: short,
        creatorDate: creatorDate,
      );

  GitRef remote(String short) => GitRef(
        name: 'refs/remotes/origin/$short',
        oid: 'r-$short',
        isHead: false,
        subject: short,
      );

  GitRef tag(String short, {int? creatorDate}) => GitRef(
        name: 'refs/tags/$short',
        oid: 't-$short',
        isHead: false,
        subject: short,
        creatorDate: creatorDate,
      );

  group('BranchViewModel.fromRefs', () {
    test('partitions pinned active stale and builds navigable', () {
      final refs = [
        local(
          'main',
          isHead: true,
          creatorDate: now.millisecondsSinceEpoch ~/ 1000,
        ),
        local(
          'feature',
          creatorDate:
              now.subtract(const Duration(days: 2)).millisecondsSinceEpoch ~/
                  1000,
        ),
        local(
          'old',
          creatorDate:
              now.subtract(const Duration(days: 120)).millisecondsSinceEpoch ~/
                  1000,
        ),
        local(
          'pin-me',
          creatorDate:
              now.subtract(const Duration(days: 200)).millisecondsSinceEpoch ~/
                  1000,
        ),
        remote('main'),
        tag('v1', creatorDate: 100),
      ];

      final vm = BranchViewModel.fromRefs(
        refs: refs,
        forge: const {},
        merged: {'feature'},
        pinned: {'pin-me'},
        collapsedSections: const {},
        filterLower: '',
        showStale: false,
        showAllTags: true,
        showAllRemotes: true,
        grouped: false,
        collapsedFolderPrefixes: const {},
        remoteTags: null,
        remotesList: const ['origin'],
        now: now,
      );

      expect(vm.pinnedLocals.map((e) => e.shortName), ['pin-me']);
      expect(vm.activeLocals.map((e) => e.shortName).toSet(), {
        'main',
        'feature',
      });
      expect(vm.staleLocals.map((e) => e.shortName), ['old']);
      // Stale not on screen when showStale is false.
      expect(vm.localsOnScreen.map((e) => e.shortName).toSet(), {
        'pin-me',
        'main',
        'feature',
      });
      expect(vm.navigable.any((r) => r.shortName == 'origin/main'), isTrue);
      expect(vm.navigable.any((r) => r.shortName == 'v1'), isTrue);
      expect(vm.dashboard.mergedDeletable, ['feature']);
      expect(vm.tagRemote, 'origin');
      expect(vm.localBranchNames, {
        'main',
        'feature',
        'old',
        'pin-me',
      });
    });

    test('filter force-expands collapsed sections for matching rows', () {
      final refs = [
        local('main', isHead: true),
        local('feature'),
        remote('feature'),
      ];
      final vm = BranchViewModel.fromRefs(
        refs: refs,
        forge: {
          'feature': const BranchForge(requestNumber: 1, isMr: false),
        },
        merged: const {},
        pinned: const {},
        collapsedSections: {
          'branches.local',
          'branches.remote',
        },
        filterLower: 'feature',
        showStale: false,
        showAllTags: false,
        showAllRemotes: false,
        grouped: false,
        collapsedFolderPrefixes: const {},
        remoteTags: null,
        remotesList: const ['origin'],
        now: now,
      );

      // With filter, collapsed flags are false.
      expect(vm.localCollapsed, isFalse);
      expect(vm.remoteCollapsed, isFalse);
      expect(vm.filteredLocals.map((e) => e.shortName), ['feature']);
      expect(vm.forge['feature']?.requestNumber, 1);
    });

    test('empty remotes list yields null tagRemote', () {
      final vm = BranchViewModel.fromRefs(
        refs: [local('main', isHead: true)],
        forge: const {},
        merged: const {},
        pinned: const {},
        collapsedSections: const {},
        filterLower: '',
        showStale: false,
        showAllTags: false,
        showAllRemotes: false,
        grouped: false,
        collapsedFolderPrefixes: const {},
        remoteTags: null,
        remotesList: const [],
        now: now,
      );
      expect(vm.tagRemote, isNull);
    });
  });

  group('buildLocalBranchListItems', () {
    test('flat mode emits depth-0 leaves', () {
      final items = buildLocalBranchListItems(
        branches: [local('a'), local('b')],
        grouped: false,
        collapsedFolderPrefixes: const {},
      );
      expect(items, hasLength(2));
      expect(items.every((e) => e is LocalBranchLeafItem), isTrue);
    });

    test('grouped mode inlines single-child folder chains', () {
      final items = buildLocalBranchListItems(
        branches: [
          local('a/b/c'),
          local('a/b/d'),
        ],
        grouped: true,
        collapsedFolderPrefixes: const {},
      );
      // One folder row a/b/ then two leaves.
      final folders = items.whereType<LocalBranchFolderItem>().toList();
      expect(folders, isNotEmpty);
      expect(folders.first.label, 'a/b/');
      expect(folders.first.path, 'a/b/');
      final leaves = items.whereType<LocalBranchLeafItem>().toList();
      expect(leaves.map((e) => e.branch.shortName).toSet(), {
        'a/b/c',
        'a/b/d',
      });
    });

    test('collapsed folder omits children', () {
      final items = buildLocalBranchListItems(
        branches: [local('feat/one'), local('feat/two')],
        grouped: true,
        collapsedFolderPrefixes: {'feat/'},
      );
      expect(items.whereType<LocalBranchFolderItem>(), hasLength(1));
      expect(items.whereType<LocalBranchLeafItem>(), isEmpty);
    });
  });

  group('nearestNavigableIndex', () {
    test('finds selected name or clamps preferred', () {
      final nav = [local('a'), local('b'), local('c')];
      expect(
        nearestNavigableIndex(
          navigable: nav,
          selectedRefName: 'refs/heads/b',
          preferredIndex: 0,
        ),
        1,
      );
      expect(
        nearestNavigableIndex(
          navigable: nav,
          selectedRefName: 'refs/heads/gone',
          preferredIndex: 99,
        ),
        2,
      );
      expect(
        nearestNavigableIndex(
          navigable: const [],
          selectedRefName: null,
          preferredIndex: 0,
        ),
        -1,
      );
    });
  });
}
