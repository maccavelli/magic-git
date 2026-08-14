import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/undo/undo_journal.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

UndoRecord record(String repoPath, String description) => UndoRecord(
  repoPath: repoPath,
  kind: UndoOpKind.commit,
  description: description,
  preHead: 'a' * 40,
  preRef: 'main',
  postHead: 'b' * 40,
  postRef: 'main',
);

void main() {
  late ProviderContainer container;
  late UndoJournal journal;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    journal = container.read(undoJournalProvider.notifier);
  });

  test('push/peek/pop is a per-repo LIFO stack', () {
    expect(journal.peek('/a'), isNull);
    journal.push(record('/a', 'first'));
    journal.push(record('/a', 'second'));
    journal.push(record('/b', 'other-repo'));

    expect(journal.peek('/a')!.description, 'second');
    journal.pop('/a');
    expect(journal.peek('/a')!.description, 'first');
    // /b's stack is untouched by /a's pops.
    expect(journal.peek('/b')!.description, 'other-repo');
    journal.pop('/a');
    expect(journal.peek('/a'), isNull);
    // Popping an empty stack is a no-op, not an error.
    journal.pop('/a');
    expect(journal.peek('/a'), isNull);
  });

  test('depth is capped: oldest entries fall off', () {
    for (var i = 0; i < UndoJournal.maxPerRepo + 5; i++) {
      journal.push(record('/a', 'op $i'));
    }
    final stack = container.read(undoJournalProvider)['/a']!;
    expect(stack.length, UndoJournal.maxPerRepo);
    expect(stack.first.description, 'op 5', reason: 'oldest dropped');
    expect(journal.peek('/a')!.description, 'op ${UndoJournal.maxPerRepo + 4}');
  });

  test('clear drops every repo stack', () {
    journal.push(record('/a', 'x'));
    journal.push(record('/b', 'y'));
    journal.clear();
    expect(journal.peek('/a'), isNull);
    expect(journal.peek('/b'), isNull);
    expect(container.read(undoJournalProvider), isEmpty);
  });

  test('a fresh mutation clears redo for only its repository', () {
    final redo = container.read(redoJournalProvider.notifier);
    final tagA = record('/a', 'Delete tag');
    final redoA = RedoRecord(
      undoRecord: tagA,
      refName: 'refs/tags/a',
      expectedOid: 'a' * 40,
      replayOid: '',
    );
    final redoB = RedoRecord(
      undoRecord: record('/b', 'Delete tag'),
      refName: 'refs/tags/b',
      expectedOid: 'b' * 40,
      replayOid: '',
    );
    redo.push(redoA);
    redo.push(redoB);

    journal.push(record('/a', 'new mutation'));

    expect(redo.peek('/a'), isNull);
    expect(redo.peek('/b'), same(redoB));
  });

  test(
    'redo is LIFO and capped, while replay can preserve the remaining stack',
    () {
      final redo = container.read(redoJournalProvider.notifier);
      for (var i = 0; i < UndoJournal.maxPerRepo + 2; i++) {
        redo.push(
          RedoRecord(
            undoRecord: record('/a', 'tag $i'),
            refName: 'refs/tags/t$i',
            expectedOid: 'a' * 40,
            replayOid: '',
          ),
        );
      }
      expect(container.read(redoJournalProvider)['/a'], hasLength(20));
      final latest = redo.peek('/a')!;
      redo.pop('/a');
      journal.push(latest.undoRecord, preserveRedo: true);
      expect(redo.peek('/a')!.description, 'tag 20');
      expect(journal.peek('/a'), same(latest.undoRecord));
    },
  );
}
