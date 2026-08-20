import '../../core/forge/branch_forge_status.dart';
import '../../core/git/branch_comparison.dart';
import '../../core/git/git_service.dart';
import 'branch_dashboard_stats.dart';

enum BranchWorkspaceMode { browse, review }

enum BranchReviewQuickFilter { all, merged, stale, conflicts }

enum BranchReviewSort { activity, name }

List<GitRef> shapePhase1ReviewBranches({
  required List<GitRef> branches,
  required Map<String, BranchReviewSummary> summaries,
  required BranchReviewQuickFilter filter,
  required BranchReviewSort sort,

  /// Full ref names known to conflict after an explicit scan. Unscanned
  /// branches are never treated as clean (they simply fail this filter).
  Set<String> conflictRefNames = const {},
}) {
  final shaped = [
    for (final branch in branches)
      if (switch (filter) {
        BranchReviewQuickFilter.all => true,
        BranchReviewQuickFilter.merged =>
          summaries[branch.name]?.mergedIntoBase ?? false,
        BranchReviewQuickFilter.stale => isBranchStale(branch),
        BranchReviewQuickFilter.conflicts => conflictRefNames.contains(
          branch.name,
        ),
      })
        branch,
  ];
  shaped.sort(switch (sort) {
    BranchReviewSort.name => (a, b) => a.shortName.compareTo(b.shortName),
    BranchReviewSort.activity => (a, b) {
      final byDate = (b.creatorDate ?? 0).compareTo(a.creatorDate ?? 0);
      return byDate != 0 ? byDate : a.shortName.compareTo(b.shortName);
    },
  });
  return shaped;
}

/// Immutable snapshot of Branches navigator/detail inputs derived from refs +
/// provider data. Built once per paint; held as a single field so keyboard and
/// actions never re-scatter forge/merged/pinned/locals into multiple mutable
/// State fields during `build`.
class BranchViewModel {
  /// Local branches currently on-screen for keyboard merge/delete/Enter
  /// (respects section collapse and stale toggle).
  final List<GitRef> localsOnScreen;

  /// All visible selectable refs in display order (local + remote + tag).
  final List<GitRef> navigable;

  /// Unfiltered local short names (for remote checkout collision checks).
  final Set<String> localBranchNames;

  /// All local branch refs (unfiltered) — worktree path lookups, etc.
  final List<GitRef> allLocalBranches;

  /// All remote-tracking refs (unfiltered) — comparison-base choices must not
  /// disappear when the navigator's free-text filter changes.
  final List<GitRef> allRemoteBranches;

  final Map<String, BranchForge> forge;
  final Set<String> merged;
  final Set<String> pinned;

  final List<GitRef> pinnedLocals;
  final List<GitRef> activeLocals;
  final List<GitRef> staleLocals;
  final List<GitRef> filteredLocals;
  final List<GitRef> filteredRemotes;
  final List<GitRef> allTags;
  final List<GitRef> visibleTags;
  final List<GitRef> visibleRemotes;

  final int totalLocals;
  final int totalRemotes;
  final int hiddenTags;
  final int hiddenRemotes;

  /// Local branches withheld by the user's hide list right now. Non-zero only
  /// while hidden branches are NOT being shown — the count the navigator
  /// offers as a reveal affordance, so a hidden branch is never unrecoverable.
  final int hiddenLocalCount;

  final bool pinnedCollapsed;
  final bool localCollapsed;
  final bool remoteCollapsed;
  final bool tagsCollapsed;

  final String filterLower;
  final bool showStale;
  final bool grouped;

  final BranchDashboardStats dashboard;

  final Map<String, String>? remoteTags;
  final String? tagRemote;
  final List<String> localOnlyTags;

  /// Preferred remote list snapshot (may be null while loading).
  final List<String>? remotesList;

  const BranchViewModel({
    required this.localsOnScreen,
    required this.navigable,
    required this.localBranchNames,
    required this.allLocalBranches,
    required this.allRemoteBranches,
    required this.forge,
    required this.merged,
    required this.pinned,
    required this.pinnedLocals,
    required this.activeLocals,
    required this.staleLocals,
    required this.filteredLocals,
    required this.filteredRemotes,
    required this.allTags,
    required this.visibleTags,
    required this.visibleRemotes,
    required this.totalLocals,
    this.hiddenLocalCount = 0,
    required this.totalRemotes,
    required this.hiddenTags,
    required this.hiddenRemotes,
    required this.pinnedCollapsed,
    required this.localCollapsed,
    required this.remoteCollapsed,
    required this.tagsCollapsed,
    required this.filterLower,
    required this.showStale,
    required this.grouped,
    required this.dashboard,
    required this.remoteTags,
    required this.tagRemote,
    required this.localOnlyTags,
    required this.remotesList,
  });

  /// Section header title: `Base (n)` or `Base (shown of total)` when filtered.
  String sectionTitle(String base, int shown, int total) =>
      filterLower.isEmpty ? '$base ($total)' : '$base ($shown of $total)';

  static const empty = BranchViewModel(
    localsOnScreen: [],
    navigable: [],
    localBranchNames: {},
    allLocalBranches: [],
    allRemoteBranches: [],
    forge: {},
    merged: {},
    pinned: {},
    pinnedLocals: [],
    activeLocals: [],
    staleLocals: [],
    filteredLocals: [],
    filteredRemotes: [],
    allTags: [],
    visibleTags: [],
    visibleRemotes: [],
    totalLocals: 0,
    totalRemotes: 0,
    hiddenTags: 0,
    hiddenRemotes: 0,
    pinnedCollapsed: false,
    localCollapsed: false,
    remoteCollapsed: false,
    tagsCollapsed: false,
    filterLower: '',
    showStale: false,
    grouped: false,
    dashboard: BranchDashboardStats(
      local: 0,
      active: 0,
      stale: 0,
      pinned: 0,
      remote: 0,
      tags: 0,
      mergedDeletable: [],
    ),
    remoteTags: null,
    tagRemote: null,
    localOnlyTags: [],
    remotesList: null,
  );

  /// Pure construction from refs + lazy provider values + UI toggles.
  factory BranchViewModel.fromRefs({
    required List<GitRef> refs,
    required Map<String, BranchForge> forge,
    required Set<String> merged,
    required Set<String> pinned,
    required Set<String> collapsedSections,
    required String filterLower,
    required bool showStale,

    /// Short names the user has hidden. Filtered out of every derived list
    /// unless [showHidden]; see [hiddenLocalCount] for the count to offer as
    /// a reveal affordance.
    Set<String> hidden = const {},
    bool showHidden = false,
    required bool showAllTags,
    required bool showAllRemotes,
    required bool grouped,
    required Set<String> collapsedFolderPrefixes,
    required Map<String, String>? remoteTags,
    required List<String>? remotesList,
    String pinnedSectionKey = 'branches.pinned',
    String localSectionKey = 'branches.local',
    String remoteSectionKey = 'branches.remote',
    String tagsSectionKey = 'branches.tags',
    int collapsedTagCount = 10,
    int collapsedRemoteCount = 25,
    DateTime? now,
  }) {
    bool sectionCollapsed(String s) =>
        filterLower.isEmpty && collapsedSections.contains(s);

    final pinnedCollapsed = sectionCollapsed(pinnedSectionKey);
    final localCollapsed = sectionCollapsed(localSectionKey);
    final remoteCollapsed = sectionCollapsed(remoteSectionKey);
    final tagsCollapsed = sectionCollapsed(tagsSectionKey);

    final totalRemotes = refs.where((r) => r.isRemote).length;
    final allLocalBranches = refs.where((r) => r.isLocalBranch).toList();
    final allRemoteBranches = refs.where((r) => r.isRemote).toList();
    final localBranchNames = {for (final r in allLocalBranches) r.shortName};

    // The ONE seam every local-branch list flows through: the pinned/active/
    // stale partition, localsOnScreen, navigable, both row builders, and
    // range-select visibility all derive from this. Hiding here keeps the
    // navigator and the shift-range list in lockstep for free.
    //
    // `allLocalBranches` stays unfiltered on purpose — Hide, bulk delete, the
    // conflict scan and the base selector all operate on the true set.
    final hiddenLocals = showHidden
        ? const <GitRef>[]
        : allLocalBranches.where((r) => hidden.contains(r.shortName)).toList();
    final visibleLocals = hiddenLocals.isEmpty
        ? allLocalBranches
        : allLocalBranches.where((r) => !hidden.contains(r.shortName)).toList();
    // The section header's denominator counts what is *showable*, not what
    // exists — otherwise "Local Branches (10 of 12)" would render ten rows
    // with no filter applied and no explanation for the missing two.
    // `hiddenLocalCount` reports those separately.
    final totalLocals = visibleLocals.length;
    final filteredLocals = visibleLocals
        .where((r) => branchNameMatchesFilter(r, filterLower))
        .toList();
    final filteredRemotes = refs
        .where((r) => r.isRemote && branchNameMatchesFilter(r, filterLower))
        .toList();
    final allTags = refs.where((r) => r.isTag).toList();
    final filteredTags = allTags
        .where((r) => branchNameMatchesFilter(r, filterLower))
        .toList();

    final pinnedLocals = <GitRef>[];
    final activeLocals = <GitRef>[];
    final staleLocals = <GitRef>[];
    for (final b in filteredLocals) {
      if (pinned.contains(b.shortName)) {
        pinnedLocals.add(b);
      } else if (isBranchStale(b, now: now)) {
        staleLocals.add(b);
      } else {
        activeLocals.add(b);
      }
    }

    filteredTags.sort((a, b) {
      final cmp = (b.creatorDate ?? -1).compareTo(a.creatorDate ?? -1);
      return cmp != 0 ? cmp : a.shortName.compareTo(b.shortName);
    });
    final visibleTags = showAllTags || filterLower.isNotEmpty
        ? filteredTags
        : filteredTags.take(collapsedTagCount).toList();
    final hiddenTags = filteredTags.length - visibleTags.length;
    final visibleRemotes = showAllRemotes || filterLower.isNotEmpty
        ? filteredRemotes
        : filteredRemotes.take(collapsedRemoteCount).toList();
    final hiddenRemotes = filteredRemotes.length - visibleRemotes.length;

    final localsOnScreen = <GitRef>[
      if (!pinnedCollapsed) ...pinnedLocals,
      if (!localCollapsed) ...[
        ...activeLocals,
        if (showStale || filterLower.isNotEmpty) ...staleLocals,
      ],
    ];
    final navigable = <GitRef>[
      ...localsOnScreen,
      if (!remoteCollapsed) ...visibleRemotes,
      if (!tagsCollapsed) ...visibleTags,
    ];

    final String? tagRemote = remotesList == null
        ? 'origin'
        : remotesList.isEmpty
        ? null
        : defaultRemote(remotesList);

    final localOnlyTags = remoteTags == null
        ? const <String>[]
        : [
            for (final t in allTags)
              if (!remoteTags.containsKey(t.shortName)) t.shortName,
          ];

    final dashboard = buildBranchDashboardStats(
      refs: refs,
      pinnedShortNames: pinned,
      mergedShortNames: merged,
      hiddenShortNames: showHidden ? const {} : hidden,
      filterLower: filterLower,
      now: now,
    );

    return BranchViewModel(
      localsOnScreen: localsOnScreen,
      navigable: navigable,
      localBranchNames: localBranchNames,
      allLocalBranches: allLocalBranches,
      allRemoteBranches: allRemoteBranches,
      forge: forge,
      merged: merged,
      pinned: pinned,
      pinnedLocals: pinnedLocals,
      activeLocals: activeLocals,
      staleLocals: staleLocals,
      filteredLocals: filteredLocals,
      filteredRemotes: filteredRemotes,
      allTags: allTags,
      visibleTags: visibleTags,
      visibleRemotes: visibleRemotes,
      totalLocals: totalLocals,
      hiddenLocalCount: hiddenLocals.length,
      totalRemotes: totalRemotes,
      hiddenTags: hiddenTags,
      hiddenRemotes: hiddenRemotes,
      pinnedCollapsed: pinnedCollapsed,
      localCollapsed: localCollapsed,
      remoteCollapsed: remoteCollapsed,
      tagsCollapsed: tagsCollapsed,
      filterLower: filterLower,
      showStale: showStale,
      grouped: grouped,
      dashboard: dashboard,
      remoteTags: remoteTags,
      tagRemote: tagRemote,
      localOnlyTags: localOnlyTags,
      remotesList: remotesList,
    );
  }
}

/// One item from pure local-branch list shaping (flat or folder-grouped).
sealed class LocalBranchListItem {
  const LocalBranchListItem();
}

/// A folder row in grouped mode.
class LocalBranchFolderItem extends LocalBranchListItem {
  final String path;
  final String label;
  final int depth;
  final int count;
  const LocalBranchFolderItem({
    required this.path,
    required this.label,
    required this.depth,
    required this.count,
  });
}

/// A branch leaf row.
class LocalBranchLeafItem extends LocalBranchListItem {
  final GitRef branch;
  final int depth;
  const LocalBranchLeafItem(this.branch, {required this.depth});
}

class _FolderNode {
  final Map<String, _FolderNode> dirs = {};
  final List<GitRef> leaves = [];
}

/// Flatten [branches] for the local list: flat, or `/`-folder tree with
/// single-child chain inlining (matches prior `branches_view` behavior).
List<LocalBranchListItem> buildLocalBranchListItems({
  required List<GitRef> branches,
  required bool grouped,
  required Set<String> collapsedFolderPrefixes,
}) {
  if (!grouped) {
    return [for (final b in branches) LocalBranchLeafItem(b, depth: 0)];
  }
  final root = _FolderNode();
  for (final b in branches) {
    final parts = b.shortName.split('/');
    var node = root;
    for (var i = 0; i < parts.length - 1; i++) {
      node = node.dirs.putIfAbsent(parts[i], _FolderNode.new);
    }
    node.leaves.add(b);
  }
  final out = <LocalBranchListItem>[];
  _emitFolder(root, '', 0, collapsedFolderPrefixes, out);
  return out;
}

void _emitFolder(
  _FolderNode node,
  String prefix,
  int depth,
  Set<String> collapsed,
  List<LocalBranchListItem> out,
) {
  final dirNames = node.dirs.keys.toList()..sort();
  for (final name in dirNames) {
    var child = node.dirs[name]!;
    var label = name;
    var path = '$prefix$name/';
    while (child.leaves.isEmpty && child.dirs.length == 1) {
      final only = child.dirs.entries.single;
      label = '$label/${only.key}';
      path = '$path${only.key}/';
      child = only.value;
    }
    final count = _leafCount(child);
    out.add(
      LocalBranchFolderItem(
        path: path,
        label: '$label/',
        depth: depth,
        count: count,
      ),
    );
    if (!collapsed.contains(path)) {
      _emitFolder(child, path, depth + 1, collapsed, out);
    }
  }
  for (final b in node.leaves) {
    out.add(LocalBranchLeafItem(b, depth: depth));
  }
}

int _leafCount(_FolderNode node) {
  var n = node.leaves.length;
  for (final d in node.dirs.values) {
    n += _leafCount(d);
  }
  return n;
}

/// Nearest surviving navigable index after a vanished selection (Phase 4 prep).
int nearestNavigableIndex({
  required List<GitRef> navigable,
  required String? selectedRefName,
  required int preferredIndex,
}) {
  if (navigable.isEmpty) return -1;
  if (selectedRefName != null) {
    for (var i = 0; i < navigable.length; i++) {
      if (navigable[i].name == selectedRefName) return i;
    }
  }
  if (preferredIndex < 0) return 0;
  if (preferredIndex >= navigable.length) return navigable.length - 1;
  return preferredIndex;
}
