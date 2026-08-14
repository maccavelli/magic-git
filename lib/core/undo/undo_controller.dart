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
  final RedoRecord? redoRecord;
  const UndoAttempt(this.status, [this.record, this.redoRecord]);
}

enum RedoStatus { done, nothingToRedo, blockedByPendingOp, stale }

class RedoAttempt {
  final RedoStatus status;
  final RedoRecord? record;
  const RedoAttempt(this.status, [this.record]);
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

  /// Serializes undo execution. [undo] `peek`s the journal and only `pop`s
  /// after awaiting the (async) undo script, so two overlapping calls — the
  /// main window's ⌘Z and the History window's `performUndo` both land on
  /// this single main-isolate instance, or a mashed double-⌘Z — would
  /// otherwise both act on the same record: run its undo script twice (the
  /// second failing, e.g. "branch already exists") and `pop` twice, silently
  /// discarding the next-older record's undo-ability. While one undo is in
  /// flight, a second is a no-op.
  bool _historyOperationInFlight = false;

  Future<UndoAttempt> undo(String repoPath, {bool force = false}) async {
    if (_historyOperationInFlight) {
      return const UndoAttempt(UndoStatus.nothingToUndo);
    }
    _historyOperationInFlight = true;
    try {
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
        _ref.read(redoJournalProvider.notifier).clearRepo(repoPath);
        return UndoAttempt(UndoStatus.stale, record);
      } on UndoDirtyException {
        return UndoAttempt(UndoStatus.dirty, record);
      }

      journal.pop(repoPath);
      final redoRecord = RedoRecord.afterSuccessfulUndo(record);
      final redoJournal = _ref.read(redoJournalProvider.notifier);
      if (redoRecord == null) {
        // An unsupported step cannot be skipped without replaying operations
        // out of order, so it terminates the redo chain.
        redoJournal.clearRepo(repoPath);
      } else {
        redoJournal.push(redoRecord);
      }
      _refresh(repoPath);
      return UndoAttempt(UndoStatus.done, record, redoRecord);
    } finally {
      _historyOperationInFlight = false;
    }
  }

  Future<RedoAttempt> redo(String repoPath) async {
    if (_historyOperationInFlight) {
      return const RedoAttempt(RedoStatus.nothingToRedo);
    }
    _historyOperationInFlight = true;
    try {
      final redoJournal = _ref.read(redoJournalProvider.notifier);
      final record = redoJournal.peek(repoPath);
      if (record == null) {
        return const RedoAttempt(RedoStatus.nothingToRedo);
      }

      final pending =
          _ref.read(pendingOpProvider(repoPath)).value ?? PendingOp.none;
      if (pending != PendingOp.none) {
        return RedoAttempt(RedoStatus.blockedByPendingOp, record);
      }

      try {
        await _ref.read(gitServiceProvider).redoExecute(record);
      } on RedoStaleException {
        redoJournal.clearRepo(repoPath);
        return RedoAttempt(RedoStatus.stale, record);
      }

      redoJournal.pop(repoPath);
      _ref
          .read(undoJournalProvider.notifier)
          .push(record.undoRecord, preserveRedo: true);
      _refresh(repoPath);
      return RedoAttempt(RedoStatus.done, record);
    } finally {
      _historyOperationInFlight = false;
    }
  }

  /// The standard post-mutation refresh (see the per-panel `_refresh`
  /// helpers): mark the mutation as our own so the watcher doesn't echo it,
  /// mark every path in the repo as possibly re-written,
  /// and invalidate the fetch families an undo can affect.
  void _refresh(String repoPath) {
    _ref.read(ownMutationTrackerProvider).mark(repoPath);
    // A mutation can rewrite any file's bytes while leaving its status record
    // untouched (an undo restoring content, say) — unknown scope.
    _ref.read(worktreeEditsProvider.notifier).noteRepo(repoPath);
    // Undo moves refs and consumes journal state the Recovery sheet renders;
    // reflog/snapshots are in the shared set so an open Recovery sheet stays
    // fresh. autoDispose makes any unwatched family free.
    for (final p in repoMutationFamilies(repoPath)) {
      _ref.invalidate(p);
    }
  }
}

final undoControllerProvider = Provider<UndoController>(UndoController.new);
