import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'undo_types.dart';

/// Per-repo stacks of undoable operations, newest last. In-memory only: the
/// reflog and snapshot refs are the durable recovery layer (Recovery sheet);
/// a persisted journal would fail undo's state validation after almost any
/// out-of-app change, so persistence would buy nothing but stale entries.
///
/// Pushed from `GitService` (via the `onUndoRecord` callback wired in
/// `gitServiceProvider`) on every successful in-scope mutation; popped by
/// `UndoController` after a successful undo or on stale-record detection.
/// Cleared alongside `ownMutationTracker` in `_invalidateRepoState` on
/// connect/disconnect/repo-switch — records are keyed purely by repoPath and
/// must not survive onto a different host that mounts the same path.
class UndoJournal extends Notifier<Map<String, List<UndoRecord>>> {
  /// Oldest entries fall off past this depth. 20 is deep enough that nobody
  /// undoes past it interactively, and keeps a long session from retaining
  /// unbounded records.
  static const int maxPerRepo = 20;

  @override
  Map<String, List<UndoRecord>> build() => const {};

  void push(UndoRecord record) {
    final stack = [...?state[record.repoPath], record];
    if (stack.length > maxPerRepo) stack.removeAt(0);
    state = {...state, record.repoPath: stack};
  }

  /// The record ⌘Z would undo next, or null when there is nothing to undo.
  UndoRecord? peek(String repoPath) {
    final stack = state[repoPath];
    return (stack == null || stack.isEmpty) ? null : stack.last;
  }

  void pop(String repoPath) {
    final stack = state[repoPath];
    if (stack == null || stack.isEmpty) return;
    state = {...state, repoPath: stack.sublist(0, stack.length - 1)};
  }

  void clear() => state = const {};
}

final undoJournalProvider =
    NotifierProvider<UndoJournal, Map<String, List<UndoRecord>>>(
      UndoJournal.new,
    );
