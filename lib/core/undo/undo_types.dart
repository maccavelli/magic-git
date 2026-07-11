/// Types shared by the undo safety net: the per-operation journal records
/// captured at mutation time (see `GitService._runCaptured`) and the typed
/// failures its validate-before-execute undo scripts can signal.
library;

/// Which operation a journal entry undoes. Determines the undo script shape —
/// see `GitService.undoExecute`.
enum UndoOpKind {
  /// `git commit` — undo is `reset --soft` back to the pre-commit HEAD, which
  /// leaves the committed content staged (the exact pre-commit state).
  commit,

  /// `git commit --amend` — undo restores the pre-amend commit with the
  /// amendment's content left staged.
  amend,

  /// `git reset --soft` — undo moves HEAD back, touching nothing else.
  resetSoft,

  /// `git reset --mixed` — undo moves HEAD back and restores the pre-reset
  /// index from a `write-tree` capture (degrades to soft-only when the index
  /// was unwritable, e.g. mid-conflict).
  resetMixed,

  /// `git checkout <ref>` — undo checks the previous branch (or detached
  /// commit) back out.
  checkout,

  /// `git branch -d/-D` — undo recreates the branch at its captured tip.
  /// Upstream/tracking config is not restored.
  deleteBranch,

  /// `git tag -d` — undo restores the ref to the captured OID via
  /// `update-ref`, so an annotated tag comes back byte-identical.
  deleteTag,

  /// `git stash drop` — undo re-stores the captured stash commit (it lands at
  /// `stash@{0}`, not its original list position).
  stashDrop,

  /// `git reset --hard` — undo moves HEAD back and re-applies the pre-reset
  /// worktree+index from a flavor-A snapshot (`stash create` anchored on a
  /// hidden ref). An empty snapshot means the tree was clean at reset time,
  /// so the plain `reset --hard` back is already exact.
  ///
  /// Also the shape of undo for the other HEAD-advancing integrations —
  /// merge, cherry-pick, revert, interactive rebase — whose undo is exactly
  /// "hard-reset back to the captured pre-op HEAD (guarded), then re-apply
  /// whatever uncommitted changes the snapshot preserved".
  resetHard,

  /// `git checkout -b` / `git branch <name> [<start>]` — undo deletes the
  /// created branch (validating its tip hasn't moved) and, when the creation
  /// checked it out, returns to the previous branch first.
  createBranch,

  /// `git stash clear` — undo re-`stash store`s every captured stash commit,
  /// oldest first, so the original stash@{n} order is preserved.
  stashClear,

  /// `git restore -- <paths>` (discard) — undo restores exactly those paths'
  /// working-tree content from the flavor-A snapshot's tree.
  discardPaths,

  /// `git restore --staged --worktree --source=HEAD -- <paths>` — undo
  /// restores the index from the snapshot's index tree (`<snap>^2`) and the
  /// working tree from its worktree tree, path-scoped.
  discardStagedPaths,

  /// `git clean -f -- <paths>` / `rm -f -- <path>` — undo restores the
  /// deleted files from a flavor-B snapshot (temp-index plumbing commit,
  /// which — unlike `stash create` — can hold untracked and ignored files).
  /// Restored files come back untracked, as they were.
  removeFilePaths,
}

/// The pre/post state one mutation captured, atomically in the same shell
/// invocation as the mutation itself. All OIDs are full hashes; empty string
/// means "not applicable" (unborn HEAD, detached HEAD, failed side-capture) —
/// never null, so shell-embedding and equality checks need no null handling.
class UndoRecord {
  final String repoPath;
  final UndoOpKind kind;

  /// Human label for toasts/logs, e.g. `Commit`, `Delete branch feat-x`.
  final String description;

  /// HEAD commit before the mutation ('' on an unborn branch).
  final String preHead;

  /// Checked-out branch shortname before the mutation ('' when detached).
  final String preRef;

  /// HEAD commit after the mutation — undo validates the repo is still here
  /// before touching anything.
  final String postHead;

  /// Checked-out branch shortname after the mutation ('' when detached).
  final String postRef;

  /// [UndoOpKind.deleteBranch]/[UndoOpKind.deleteTag]: the deleted ref's short
  /// name.
  final String refName;

  /// The OID a deleted ref pointed at (tag *object* for an annotated tag) or
  /// the dropped stash commit.
  final String deletedOid;

  /// [UndoOpKind.stashDrop]: the dropped stash's subject, reused as the
  /// re-stored stash's message.
  final String stashSubject;

  /// [UndoOpKind.resetMixed]: `git write-tree` of the pre-reset index ('' when
  /// the capture degraded).
  final String preIndexTree;

  /// The pre-destroy snapshot commit (flavor A for tracked-content destroys,
  /// flavor B for untracked deletions), anchored under
  /// `refs/magic-git/snapshots/` so gc can't reap it. '' when the snapshot
  /// degraded (or, for [UndoOpKind.resetHard], the tree was simply clean).
  final String snapshotOid;

  /// The paths a path-scoped undo restores — exactly the paths the original
  /// operation destroyed, never a blanket apply.
  final List<String> paths;

  /// [UndoOpKind.stashClear]: the cleared stashes as `<oid> <subject>` lines,
  /// newest first (reflog order).
  final List<String> stashEntries;

  final DateTime at;

  UndoRecord({
    required this.repoPath,
    required this.kind,
    required this.description,
    required this.preHead,
    required this.preRef,
    required this.postHead,
    required this.postRef,
    this.refName = '',
    this.deletedOid = '',
    this.stashSubject = '',
    this.preIndexTree = '',
    this.snapshotOid = '',
    this.paths = const [],
    this.stashEntries = const [],
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

/// The raw pre/post state one `_runCaptured` invocation observed, handed to
/// the per-mutation `record` builder. Same empty-string conventions as
/// [UndoRecord]; [extras] holds the op-specific side captures (deleted-ref
/// OID, stash subject, …) in the order they were requested.
class UndoCapture {
  final String preHead;
  final String preRef;
  final String postHead;
  final String postRef;
  final List<String> extras;

  const UndoCapture({
    required this.preHead,
    required this.preRef,
    required this.postHead,
    required this.postRef,
    this.extras = const [],
  });

  /// Builds a record carrying this capture's pre/post state; the caller
  /// supplies the op identity and any side-capture fields.
  UndoRecord toRecord({
    required String repoPath,
    required UndoOpKind kind,
    required String description,
    String refName = '',
    String deletedOid = '',
    String stashSubject = '',
    String preIndexTree = '',
    String snapshotOid = '',
    List<String> paths = const [],
    List<String> stashEntries = const [],
  }) => UndoRecord(
    repoPath: repoPath,
    kind: kind,
    description: description,
    preHead: preHead,
    preRef: preRef,
    postHead: postHead,
    postRef: postRef,
    refName: refName,
    deletedOid: deletedOid,
    stashSubject: stashSubject,
    preIndexTree: preIndexTree,
    snapshotOid: snapshotOid,
    paths: paths,
    stashEntries: stashEntries,
  );
}

/// The undo script's validation found the repository no longer in the
/// recorded post-operation state (exit 42) — something else moved HEAD or
/// recreated the ref since. The stale record should be discarded.
class UndoStaleException implements Exception {
  final UndoRecord record;
  UndoStaleException(this.record);

  @override
  String toString() =>
      'UndoStaleException: repository changed since "${record.description}"';
}

/// The undo would overwrite working-tree content that changed after the
/// original operation (exit 43). Callers may confirm with the user and retry
/// with `force: true`, which strips this guard only — state validation (exit
/// 42) always runs.
class UndoDirtyException implements Exception {
  final UndoRecord record;
  UndoDirtyException(this.record);

  @override
  String toString() =>
      'UndoDirtyException: files changed since "${record.description}"';
}
