/// The repository pane's one file selection, shared across every surface that
/// shows it (audit M13).
///
/// It used to live in three independent places: `RepoStatusView._selectedPaths`
/// for the Changes list, plus a private `_selectedPath` inside EACH of the two
/// `FileView` instances the repository pane builds (the docked right pane and
/// the navigator's Files tab). Because the two file trees are mutually
/// exclusive by layout, switching Changes↔Files lost the highlight every time,
/// and the docked tree and the tab tree could disagree about what was selected.
///
/// The payload is [RepoChangeSelection] — already immutable, already tested,
/// and already carrying the `section` and reconcile/rehome logic the Changes
/// list depends on. (Plan 0005 minted a `WorkspaceSelection` type for this job
/// but never wired it, and it has no `section`, so it is not usable here.)
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/git_porcelain_parser.dart';
import 'repo_change_model.dart';

/// Holds the selection for one repository path.
///
/// Riverpod 3 hands a family's argument to the notifier's *constructor*, hence
/// the field — same shape as `WorktreeSubPage`.
class RepoFileSelection extends Notifier<RepoChangeSelection> {
  RepoFileSelection(this.repoPath);

  final String repoPath;

  @override
  RepoChangeSelection build() => const RepoChangeSelection.empty();

  void set(RepoChangeSelection next) {
    if (state != next) state = next;
  }

  void clear() => state = const RepoChangeSelection.empty();

  /// Replaces the selection with exactly [path], keeping whatever section is
  /// current. The file trees are single-select; the multi-select vocabulary
  /// belongs to the Changes list.
  ///
  /// Marked [RepoChangeSelection.fromTree] so a clean file — which appears in
  /// no status section — survives [reconcile] instead of being mistaken for a
  /// stale Changes-list entry.
  void selectOnly(String path) {
    state = state.copyWith(paths: {path}, anchor: path, fromTree: true);
  }

  void select(
    List<RepoChangeRow> rows,
    String path,
    RepoChangeSection section, {
    bool toggle = false,
    bool range = false,
  }) {
    state = state.select(rows, path, section, toggle: toggle, range: range);
  }

  /// Drops paths that no longer exist in [status], rehoming any that merely
  /// moved between sections. A selection whose paths are absent from the
  /// status entirely is left alone — see [RepoChangeSelection.reconcile].
  void reconcile(GitStatus status) => set(state.reconcile(status));
}

/// Keyed by bare repo path, matching how both `RepoStatusView` and `FileView`
/// are already parameterised — so a repo switch yields a different instance
/// and the previous selection cannot bleed across.
///
/// Deliberately NOT in `repoScopedFetchFamilies`: that list is for fetches,
/// and `ref.invalidate` on a UI-state notifier there would be a semantic
/// mismatch. `ConnectionController._invalidateRepoState` clears it explicitly
/// alongside the other non-family UI state.
final repoFileSelectionProvider =
    NotifierProvider.family<
      RepoFileSelection,
      RepoChangeSelection,
      String
    >(RepoFileSelection.new);
