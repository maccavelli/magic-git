// UndoRecord's wire form — the History window forwards its mutations' records
// to the main window's journal, so a lossless round trip is what keeps ⌘Z
// working across windows.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

void main() {
  test('a fully populated record round-trips losslessly', () {
    final record = UndoRecord(
      repoPath: '/srv/repo',
      kind: UndoOpKind.stashClear,
      description: 'Clearing of 2 stashes',
      preHead: 'a' * 40,
      preRef: 'main',
      postHead: 'b' * 40,
      postRef: 'feature',
      refName: 'doomed',
      deletedOid: 'c' * 40,
      stashSubject: 'On main: wip',
      preIndexTree: 'd' * 40,
      snapshotOid: 'e' * 40,
      paths: ['a.txt', 'dir with spaces/ü.txt'],
      stashEntries: ['${'f' * 40} On main: one', '${'0' * 40} On main: two'],
      at: DateTime.utc(2026, 7, 11, 12, 30),
    );

    final decoded = UndoRecord.fromJson(record.toJson())!;
    expect(decoded.repoPath, record.repoPath);
    expect(decoded.kind, UndoOpKind.stashClear);
    expect(decoded.description, record.description);
    expect(decoded.preHead, record.preHead);
    expect(decoded.preRef, record.preRef);
    expect(decoded.postHead, record.postHead);
    expect(decoded.postRef, record.postRef);
    expect(decoded.refName, record.refName);
    expect(decoded.deletedOid, record.deletedOid);
    expect(decoded.stashSubject, record.stashSubject);
    expect(decoded.preIndexTree, record.preIndexTree);
    expect(decoded.snapshotOid, record.snapshotOid);
    expect(decoded.paths, record.paths);
    expect(decoded.stashEntries, record.stashEntries);
    expect(decoded.at, record.at);
  });

  test('defaults survive a minimal record', () {
    final record = UndoRecord(
      repoPath: '/r',
      kind: UndoOpKind.commit,
      description: 'Commit',
      preHead: 'a' * 40,
      preRef: 'main',
      postHead: 'b' * 40,
      postRef: 'main',
    );
    final decoded = UndoRecord.fromJson(record.toJson())!;
    expect(decoded.refName, '');
    expect(decoded.snapshotOid, '');
    expect(decoded.paths, isEmpty);
    expect(decoded.stashEntries, isEmpty);
  });

  test('an unknown kind (version skew) is dropped, not guessed at', () {
    final json = UndoRecord(
      repoPath: '/r',
      kind: UndoOpKind.commit,
      description: 'Commit',
      preHead: 'a' * 40,
      preRef: 'main',
      postHead: 'b' * 40,
      postRef: 'main',
    ).toJson();
    json['kind'] = 'teleport';
    expect(UndoRecord.fromJson(json), isNull);
  });
}
