// The undo controller's reentrancy guard: overlapping undo() calls — the main
// window's ⌘Z and the History window's proxied performUndo both land on this
// one main-isolate instance — must not both act on the same journal record.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/undo/undo_controller.dart';
import 'package:remote_magic_git/core/undo/undo_journal.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

/// A GitService whose undo blocks on a gate, so a test can hold one undo
/// in flight while a second is issued — and counts how many actually ran.
class _BlockingGit extends GitService {
  _BlockingGit() : super(SSHCommandExecutor(SSHClientManager()));
  int undoCalls = 0;
  final gate = Completer<void>();

  @override
  Future<void> undoExecute(UndoRecord record, {bool force = false}) async {
    undoCalls++;
    await gate.future;
  }
}

class _RecordingGit extends GitService {
  _RecordingGit() : super(SSHCommandExecutor(SSHClientManager()));

  int undoCalls = 0;
  int redoCalls = 0;
  bool staleRedo = false;

  @override
  Future<void> undoExecute(UndoRecord record, {bool force = false}) async {
    undoCalls++;
  }

  @override
  Future<void> redoExecute(RedoRecord record) async {
    redoCalls++;
    if (staleRedo) throw RedoStaleException(record);
  }
}

void main() {
  final record = UndoRecord(
    repoPath: '/repo',
    kind: UndoOpKind.commit,
    description: 'Commit',
    preHead: 'a' * 40,
    preRef: 'main',
    postHead: 'b' * 40,
    postRef: 'main',
  );

  test('a second undo while one is in flight is a no-op — the record runs and '
      'pops exactly once', () async {
    final git = _BlockingGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        // Positively "no pending op" so the guard, not the probe, is what's
        // under test.
        pendingOpProvider.overrideWith((ref, repoPath) => PendingOp.none),
      ],
    );
    addTearDown(container.dispose);
    container.read(undoJournalProvider.notifier).push(record);

    final controller = container.read(undoControllerProvider);
    // First call runs synchronously up to the blocked undoExecute; the second
    // is issued while the first is still in flight.
    final first = controller.undo('/repo');
    final second = controller.undo('/repo');

    // The second returns immediately without touching the git undo.
    expect((await second).status, UndoStatus.nothingToUndo);
    expect(git.undoCalls, 1, reason: 'the blocked first undo is the only run');

    git.gate.complete();
    expect((await first).status, UndoStatus.done);
    expect(git.undoCalls, 1, reason: 'the undo script ran exactly once');
    expect(
      container.read(undoJournalProvider.notifier).peek('/repo'),
      isNull,
      reason: 'the record was popped once, not twice',
    );

    // With the journal now empty, a fresh (non-overlapping) undo still works —
    // the guard only blocks concurrency, never a later sequential undo.
    expect((await controller.undo('/repo')).status, UndoStatus.nothingToUndo);
  });

  test(
    'a successful safe undo records redo; redo restores undo history',
    () async {
      final git = _RecordingGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          pendingOpProvider.overrideWith((ref, repoPath) => PendingOp.none),
        ],
      );
      addTearDown(container.dispose);
      final tagRecord = UndoRecord(
        repoPath: '/repo',
        kind: UndoOpKind.deleteTag,
        description: 'Delete tag v1',
        preHead: 'a' * 40,
        preRef: 'main',
        postHead: 'a' * 40,
        postRef: 'main',
        refName: 'v1',
        deletedOid: 'b' * 40,
      );
      container.read(undoJournalProvider.notifier).push(tagRecord);
      final controller = container.read(undoControllerProvider);

      final undo = await controller.undo('/repo');
      expect(undo.status, UndoStatus.done);
      expect(undo.redoRecord, isNotNull);
      expect(
        container.read(redoJournalProvider.notifier).peek('/repo'),
        isNotNull,
      );

      final redo = await controller.redo('/repo');
      expect(redo.status, RedoStatus.done);
      expect(git.redoCalls, 1);
      expect(
        container.read(redoJournalProvider.notifier).peek('/repo'),
        isNull,
      );
      expect(
        container.read(undoJournalProvider.notifier).peek('/repo'),
        same(tagRecord),
      );
    },
  );

  test(
    'an unsupported undo explicitly produces no redo and ends the chain',
    () async {
      final git = _RecordingGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          pendingOpProvider.overrideWith((ref, repoPath) => PendingOp.none),
        ],
      );
      addTearDown(container.dispose);
      final redoJournal = container.read(redoJournalProvider.notifier);
      redoJournal.push(
        RedoRecord(
          undoRecord: record,
          refName: 'refs/tags/older',
          expectedOid: 'c' * 40,
          replayOid: '',
        ),
      );
      container
          .read(undoJournalProvider.notifier)
          .push(record, preserveRedo: true);

      final attempt = await container
          .read(undoControllerProvider)
          .undo('/repo');

      expect(attempt.status, UndoStatus.done);
      expect(attempt.redoRecord, isNull);
      expect(redoJournal.peek('/repo'), isNull);
    },
  );

  test('a stale redo is discarded without restoring an undo entry', () async {
    final git = _RecordingGit()..staleRedo = true;
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        pendingOpProvider.overrideWith((ref, repoPath) => PendingOp.none),
      ],
    );
    addTearDown(container.dispose);
    final tagRecord = UndoRecord(
      repoPath: '/repo',
      kind: UndoOpKind.createTag,
      description: 'Create tag v1',
      preHead: 'a' * 40,
      preRef: 'main',
      postHead: 'a' * 40,
      postRef: 'main',
      refName: 'v1',
      deletedOid: 'b' * 40,
    );
    final redoJournal = container.read(redoJournalProvider.notifier);
    redoJournal.push(RedoRecord.afterSuccessfulUndo(tagRecord)!);

    final attempt = await container.read(undoControllerProvider).redo('/repo');

    expect(attempt.status, RedoStatus.stale);
    expect(redoJournal.peek('/repo'), isNull);
    expect(container.read(undoJournalProvider.notifier).peek('/repo'), isNull);
  });
}
