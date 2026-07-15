import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../tabs/tab_ui_providers.dart';
import 'worktree_access.dart';

/// Sidebar index of the Worktrees panel — defined once, here, next to the
/// navigation helper that uses it. (It used to be re-declared privately in
/// each feature that navigates here, with a comment lamenting the circular
/// import that forced the copy.)
const int kWorktreesPageIndex = 6;

/// Canonical glyph for a git worktree: SF Symbol **tree**
/// ([CupertinoIcons.tree]). Do **not** use `square_split_2x1` — that means
/// side-by-side / split view elsewhere in the app.
const IconData kWorktreeIcon = CupertinoIcons.tree;

/// The one wording for "this branch is held by another worktree" — used by
/// the Branches panel's badge and History's ref chips, which had drifted into
/// separate copies of the same sentence.
String checkedOutElsewhereMessage(String worktreePath) =>
    'Checked out in the worktree at $worktreePath';

/// THE way to bring a worktree's workspace forward from anywhere in the app:
/// sandbox grant first (prompts once, then never again — a worktree lives
/// outside the main repo's grant), then open its tab, then surface the
/// Worktrees panel. app_shell (the command palette's path) and the Branches
/// panel each hand-rolled this trio and drifted on the page-selection half.
Future<void> switchToWorktree(
  BuildContext context,
  WidgetRef ref,
  String worktreePath,
) async {
  final ok = await ref
      .read(worktreeAccessProvider)
      .ensure(context, worktreePath);
  if (!ok || !context.mounted) return;
  ref.read(worktreeTabsProvider.notifier).open(worktreePath);
  ref.read(pageIndexProvider.notifier).select(kWorktreesPageIndex);
  ref.read(visitedPagesProvider.notifier).visit(kWorktreesPageIndex);
}

/// The Worktrees panel's own tab strip: an always-present **Overview** (the
/// management table) plus one tab per worktree the user has opened.
///
/// These are deliberately NOT the app's global tabs ([TabsController]). That
/// strip is the *repository* switcher — it caps at 8 and dedupes by repo path,
/// and a power user runs far more worktrees than that. Letting worktrees compete
/// for those slots is exactly the mistake Fork (#2735) and GitHub Desktop
/// (#22211) shipped and got complaints about: the repo switcher fills with
/// near-identical entries and stops being useful.
///
/// So worktrees live in their own space, and the main repository stays clean.
/// A worktree you intend to live in all day can still be promoted to a real
/// window from its row menu ("Open in Window").
///
/// Lives in each tab's own root ProviderContainer, so which worktrees are open
/// survives the panel being backgrounded — same reasoning as [pageIndexProvider].
class WorktreeTabs {
  /// Worktree paths with an open tab, in the order they were opened.
  final List<String> open;

  /// The selected worktree, or null for the Overview tab.
  final String? selected;

  const WorktreeTabs({this.open = const [], this.selected});
}

class WorktreeTabsNotifier extends Notifier<WorktreeTabs> {
  @override
  WorktreeTabs build() => const WorktreeTabs();

  /// Opens [path] (or focuses it if already open) and selects it.
  void open(String path) {
    state = WorktreeTabs(
      open: state.open.contains(path) ? state.open : [...state.open, path],
      selected: path,
    );
  }

  void select(String? path) {
    if (path != null && !state.open.contains(path)) return;
    state = WorktreeTabs(open: state.open, selected: path);
  }

  void close(String path) {
    final open = state.open.where((p) => p != path).toList();
    state = WorktreeTabs(
      open: open,
      // Closing the selected tab falls back to the Overview rather than guessing
      // a neighbour — the Overview is where you go to pick another one anyway.
      selected: state.selected == path ? null : state.selected,
    );
  }

  /// Drops tabs for worktrees that no longer exist (removed here, or pruned in
  /// a terminal). Without this a tab would linger pointing at a dead path and
  /// every git call in it would fail.
  void retain(Set<String> existing) {
    final open = state.open.where(existing.contains).toList();
    if (open.length == state.open.length) return;
    state = WorktreeTabs(
      open: open,
      selected: open.contains(state.selected) ? state.selected : null,
    );
  }

  void reset() => state = const WorktreeTabs();
}

final worktreeTabsProvider =
    NotifierProvider<WorktreeTabsNotifier, WorktreeTabs>(
      WorktreeTabsNotifier.new,
    );

/// Which sub-panel (Changes / History / Branches / Stashes) a given worktree's
/// tab is showing. Keyed by worktree path so each keeps its own place.
///
/// Riverpod 3 hands a family's argument to the notifier's *constructor* (not to
/// `build()`, which takes none) — hence the field.
class WorktreeSubPage extends Notifier<int> {
  WorktreeSubPage(this.worktreePath);

  final String worktreePath;

  @override
  int build() => 0;

  void select(int index) {
    if (state != index) state = index;
  }
}

final worktreeSubPageProvider =
    NotifierProvider.family<WorktreeSubPage, int, String>(WorktreeSubPage.new);

/// Which sub-panels of a worktree have been visited, so an unvisited one renders
/// a cheap placeholder instead of eagerly spawning git reads for a tab the user
/// never looked at. Mirrors [visitedPagesProvider].
class WorktreeVisitedSubPages extends Notifier<Set<int>> {
  WorktreeVisitedSubPages(this.worktreePath);

  final String worktreePath;

  @override
  Set<int> build() => const {0};

  void visit(int index) {
    if (!state.contains(index)) state = {...state, index};
  }
}

final worktreeVisitedSubPagesProvider =
    NotifierProvider.family<WorktreeVisitedSubPages, Set<int>, String>(
      WorktreeVisitedSubPages.new,
    );
