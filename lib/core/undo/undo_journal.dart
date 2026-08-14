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

  void push(UndoRecord record, {bool preserveRedo = false}) {
    if (!preserveRedo) {
      ref.read(redoJournalProvider.notifier).clearRepo(record.repoPath);
    }
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

/// Per-repository replay stacks. Only [RedoRecord]s that passed the feasibility
/// gate enter this journal. A fresh mutation clears its repository's stack via
/// [UndoJournal.push], preserving the usual linear undo/redo history.
class RedoJournal extends Notifier<Map<String, List<RedoRecord>>> {
  @override
  Map<String, List<RedoRecord>> build() => const {};

  void push(RedoRecord record) {
    final stack = [...?state[record.repoPath], record];
    if (stack.length > UndoJournal.maxPerRepo) stack.removeAt(0);
    state = {...state, record.repoPath: stack};
  }

  RedoRecord? peek(String repoPath) {
    final stack = state[repoPath];
    return (stack == null || stack.isEmpty) ? null : stack.last;
  }

  void pop(String repoPath) {
    final stack = state[repoPath];
    if (stack == null || stack.isEmpty) return;
    state = {...state, repoPath: stack.sublist(0, stack.length - 1)};
  }

  void clearRepo(String repoPath) {
    if (!state.containsKey(repoPath)) return;
    final next = {...state}..remove(repoPath);
    state = next;
  }

  void clear() => state = const {};
}

final redoJournalProvider =
    NotifierProvider<RedoJournal, Map<String, List<RedoRecord>>>(
      RedoJournal.new,
    );

/// Undo records raised by a mutation performed in the *History* window.
///
/// That window shows its own "⌘Z to undo" toast locally (the user is looking
/// at it), then forwards the record to this main-isolate journal so ⌘Z from
/// either window can undo it. But the main window's [UndoToastOverlay] is
/// journal-growth-driven, so without this set it would pop a *second* toast
/// for the very same action. The bridge [mark]s each forwarded record; the
/// overlay [take]s it and stays silent. Identity equality is enough — the same
/// record instance the bridge pushes is the one the overlay reads back.
class HistoryOriginUndoNotifier extends Notifier<Set<UndoRecord>> {
  @override
  Set<UndoRecord> build() => const {};

  void mark(UndoRecord record) => state = {...state, record};

  /// True (consuming the mark) when [record] originated in the History window,
  /// so the caller should not raise its own toast for it.
  bool take(UndoRecord record) {
    if (!state.contains(record)) return false;
    state = {...state}..remove(record);
    return true;
  }
}

final historyOriginUndoProvider =
    NotifierProvider<HistoryOriginUndoNotifier, Set<UndoRecord>>(
      HistoryOriginUndoNotifier.new,
    );
