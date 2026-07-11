import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_service.dart';
import '../providers/app_providers.dart';
import 'undo_journal.dart';
import 'undo_types.dart';

/// How one undo attempt ended. [record] is the entry it acted on (null only
/// for [UndoStatus.nothingToUndo]) so callers can name the operation in
/// toasts and dialogs.
enum UndoStatus {
  /// The undo ran; the record was popped and the repo state refreshed.
  done,

  /// The journal is empty for this repo.
  nothingToUndo,

  /// A merge/cherry-pick/revert/rebase is mid-flight — the pending-op banner's
  /// continue/abort buttons own recovery there, not ⌘Z.
  blockedByPendingOp,

  /// The repository is no longer in the recorded post-op state; the stale
  /// record has already been popped.
  stale,

  /// The working tree changed where this undo would write. The record is
  /// kept; confirm with the user, then retry with `force: true`.
  dirty,
}

class UndoAttempt {
  final UndoStatus status;
  final UndoRecord? record;
  const UndoAttempt(this.status, [this.record]);
}

/// Orchestrates ⌘Z: peeks the journal, guards against in-flight git
/// operations, hands the record to `GitService.undoExecute` (one atomic
/// validate-then-execute round trip), and on success pops the entry and
/// refreshes the same providers every mutation call site refreshes.
///
/// A [GitException] from the undo script itself (e.g. checkout refusing to
/// overwrite local changes) propagates to the caller — it's a normal command
/// failure, surfaced like any other.
class UndoController {
  UndoController(this._ref);
  final Ref _ref;

  Future<UndoAttempt> undo(String repoPath, {bool force = false}) async {
    final journal = _ref.read(undoJournalProvider.notifier);
    final record = journal.peek(repoPath);
    if (record == null) return const UndoAttempt(UndoStatus.nothingToUndo);

    // Only block when a pending op is positively known — while the probe is
    // still loading, let the undo script's own validation be the arbiter.
    final pending =
        _ref.read(pendingOpProvider(repoPath)).value ?? PendingOp.none;
    if (pending != PendingOp.none) {
      return UndoAttempt(UndoStatus.blockedByPendingOp, record);
    }

    try {
      await _ref.read(gitServiceProvider).undoExecute(record, force: force);
    } on UndoStaleException {
      journal.pop(repoPath);
      return UndoAttempt(UndoStatus.stale, record);
    } on UndoDirtyException {
      return UndoAttempt(UndoStatus.dirty, record);
    }

    journal.pop(repoPath);
    _refresh(repoPath);
    return UndoAttempt(UndoStatus.done, record);
  }

  /// The standard post-mutation refresh (see the per-panel `_refresh`
  /// helpers): mark the mutation as our own so the watcher doesn't echo it,
  /// bump the edit generation so the status memo can't swallow the refresh,
  /// and invalidate the fetch families an undo can affect.
  void _refresh(String repoPath) {
    _ref.read(ownMutationTrackerProvider).mark(repoPath);
    noteWorktreeEdit(repoPath);
    _ref.invalidate(statusProvider(repoPath));
    _ref.invalidate(logProvider(repoPath));
    _ref.invalidate(refsProvider(repoPath));
    _ref.invalidate(stashesProvider(repoPath));
    // Undo moves refs and consumes journal state the Recovery sheet renders;
    // autoDispose makes these free when the sheet is closed.
    _ref.invalidate(reflogProvider(repoPath));
    _ref.invalidate(magicSnapshotsProvider(repoPath));
  }
}

final undoControllerProvider = Provider<UndoController>(UndoController.new);
