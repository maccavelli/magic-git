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
}
