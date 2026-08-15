/// Which panel owns each keymap action id.
///
/// Panel-scoped actions are never run by the shell directly: the shell switches
/// to the owning panel and parks the id as a `PaletteIntent`, which that
/// panel's `PanelShortcuts` consumes on its next build and runs through the
/// panel's own handler — with every guard (busy gates, selection requirements,
/// dirty-tree prompts) intact. That routing needs to know where each action
/// lives, and both entry points — the ⌘K palette and the native menu bar —
/// need the same answer, so it is stated once here.
///
/// The index is the `IndexedStack` page index in `AppShell._pages`, which is
/// also what `global.panelN` selects.
library;

const int kRepositoryPanel = 0;
const int kHistoryPanel = 1;
const int kBranchesPanel = 2;
const int kStashesPanel = 3;
const int kForgePanel = 4;
const int kWorktreesPanel = 5;

/// Action id → owning panel index. Every panel-scoped id the palette or the
/// menu bar can dispatch must appear here; `global.*`, `commit.*` and
/// `viewer.*` deliberately do not, because no panel owns them.
const Map<String, int> kPanelActionOwner = {
  // Repository — sync, staging, stash, commit.
  'repository.fetch': kRepositoryPanel,
  'repository.pull': kRepositoryPanel,
  'repository.pullRebase': kRepositoryPanel,
  'repository.pullMerge': kRepositoryPanel,
  'repository.push': kRepositoryPanel,
  'repository.pushSetUpstream': kRepositoryPanel,
  'repository.pushTags': kRepositoryPanel,
  'repository.forcePush': kRepositoryPanel,
  'repository.forcePushHard': kRepositoryPanel,
  'repository.sync': kRepositoryPanel,
  'repository.stash': kRepositoryPanel,
  'repository.stageAll': kRepositoryPanel,
  'repository.unstageAll': kRepositoryPanel,
  'repository.toggleStage': kRepositoryPanel,
  'repository.discard': kRepositoryPanel,
  'repository.focusCommit': kRepositoryPanel,
  'repository.amend': kRepositoryPanel,
  'repository.abortPending': kRepositoryPanel,
  'repository.toggleSplitDiff': kRepositoryPanel,
  'repository.toggleIgnoreWhitespace': kRepositoryPanel,
  'repository.toggleExpandContext': kRepositoryPanel,

  // History — commit-level operations.
  'history.copySha': kHistoryPanel,
  'history.checkout': kHistoryPanel,
  'history.branchFrom': kHistoryPanel,
  'history.cherryPick': kHistoryPanel,
  'history.rebaseFrom': kHistoryPanel,
  'history.amend': kHistoryPanel,
  'history.filter': kHistoryPanel,
  'history.zoomIn': kHistoryPanel,
  'history.zoomOut': kHistoryPanel,
  'history.zoomReset': kHistoryPanel,

  // Branches.
  'branches.newBranch': kBranchesPanel,
  'branches.createTag': kBranchesPanel,
  'branches.merge': kBranchesPanel,
  'branches.delete': kBranchesPanel,
  'branches.publish': kBranchesPanel,
  'branches.createRequest': kBranchesPanel,
  'branches.openCi': kBranchesPanel,
  'branches.compare': kBranchesPanel,

  // Stashes.
  'stashes.apply': kStashesPanel,
  'stashes.pop': kStashesPanel,
  'stashes.drop': kStashesPanel,
  'stashes.stashWithMessage': kStashesPanel,
  'stashes.applyLatest': kStashesPanel,
  'stashes.popLatest': kStashesPanel,
  'stashes.clearAll': kStashesPanel,

  // Forge — the two hosts' ids both land on the same panel; which set is
  // available at a given moment depends on the detected forge.
  'github.newPr': kForgePanel,
  'github.approve': kForgePanel,
  'github.merge': kForgePanel,
  'github.rerun': kForgePanel,
  'gitlab.newMr': kForgePanel,
  'gitlab.approve': kForgePanel,
  'gitlab.merge': kForgePanel,
  'gitlab.retry': kForgePanel,
  'forge.newIssue': kForgePanel,
  'forge.cancelAutoMerge': kForgePanel,

  // Worktrees.
  'worktrees.add': kWorktreesPanel,
  'worktrees.open': kWorktreesPanel,
  'worktrees.lock': kWorktreesPanel,
  'worktrees.unlock': kWorktreesPanel,
  'worktrees.move': kWorktreesPanel,
  'worktrees.repair': kWorktreesPanel,
  'worktrees.repairAll': kWorktreesPanel,
  'worktrees.prune': kWorktreesPanel,
  'worktrees.remove': kWorktreesPanel,
};

/// The panel that owns [actionId], or null when no panel does (a `global.*`
/// action, or an id that was never registered).
int? panelOwnerOf(String actionId) => kPanelActionOwner[actionId];
