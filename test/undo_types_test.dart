import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

void main() {
  group('UndoRecord', () {
    final base = UndoRecord(
      repoPath: '/srv/repo',
      kind: UndoOpKind.commit,
      description: 'Commit',
      preHead: 'aaaa111111111111111111111111111111111111',
      preRef: 'main',
      postHead: 'bbbb222222222222222222222222222222222222',
      postRef: 'main',
    );

    test('toJson produces a complete map', () {
      final json = base.toJson();
      expect(json['repoPath'], '/srv/repo');
      expect(json['kind'], 'commit');
      expect(json['description'], 'Commit');
      expect(json['preHead'], 'aaaa111111111111111111111111111111111111');
      expect(json['preRef'], 'main');
      expect(json['postHead'], 'bbbb222222222222222222222222222222222222');
      expect(json['postRef'], 'main');
      expect(json['refName'], '');
      expect(json['deletedOid'], '');
      expect(json['stashSubject'], '');
      expect(json['preIndexTree'], '');
      expect(json['worktreeTree'], '');
      expect(json['snapshotOid'], '');
      expect(json['paths'], <String>[]);
      expect(json['stashEntries'], <String>[]);
      expect(json['at'], isA<String>());
    });

    test('fromJson round-trips to the same record', () {
      final json = base.toJson();
      final restored = UndoRecord.fromJson(json);
      expect(restored, isNotNull);
      expect(restored!.repoPath, base.repoPath);
      expect(restored.kind, base.kind);
      expect(restored.description, base.description);
      expect(restored.preHead, base.preHead);
      expect(restored.preRef, base.preRef);
      expect(restored.postHead, base.postHead);
      expect(restored.postRef, base.postRef);
      expect(restored.at.toIso8601String(), base.at.toIso8601String());
    });

    test('fromJson restores all optional fields', () {
      final record = UndoRecord(
        repoPath: '/srv/repo',
        kind: UndoOpKind.deleteBranch,
        description: 'Delete branch feat-x',
        preHead: 'aaa',
        preRef: 'main',
        postHead: 'bbb',
        postRef: 'main',
        refName: 'feat-x',
        deletedOid: 'ccc',
        stashSubject: 'WIP on feat-x',
        preIndexTree: 'ddd',
        worktreeTree: 'eee',
        snapshotOid: 'fff',
        paths: ['src/a.dart', 'src/b.dart'],
        stashEntries: ['ggg WIP', 'hhh Fix'],
      );
      final json = record.toJson();
      final restored = UndoRecord.fromJson(json)!;

      expect(restored.refName, 'feat-x');
      expect(restored.deletedOid, 'ccc');
      expect(restored.stashSubject, 'WIP on feat-x');
      expect(restored.preIndexTree, 'ddd');
      expect(restored.worktreeTree, 'eee');
      expect(restored.snapshotOid, 'fff');
      expect(restored.paths, ['src/a.dart', 'src/b.dart']);
      expect(restored.stashEntries, ['ggg WIP', 'hhh Fix']);
    });

    test('fromJson returns null for an unknown UndoOpKind (version skew)', () {
      final json = base.toJson();
      json['kind'] = 'nonexistentOp';
      expect(UndoRecord.fromJson(json), isNull);
    });

    test('fromJson handles null/empty fields gracefully', () {
      final restored = UndoRecord.fromJson(<Object?, Object?>{
        'repoPath': null,
        'kind': 'commit',
        'description': null,
        'preHead': null,
        'preRef': null,
        'postHead': null,
        'postRef': null,
        'refName': null,
        'deletedOid': null,
        'stashSubject': null,
        'preIndexTree': null,
        'worktreeTree': null,
        'snapshotOid': null,
        'paths': null,
        'stashEntries': null,
        'at': null,
      });
      expect(restored, isNotNull);
      // All optional fields default to empty/null-safe values.
      expect(restored!.repoPath, '');
      expect(restored.description, '');
      expect(restored.refName, '');
      expect(restored.paths, <String>[]);
      expect(restored.stashEntries, <String>[]);
      expect(restored.at, isA<DateTime>());
    });

    test('every UndoOpKind round-trips through json', () {
      for (final kind in UndoOpKind.values) {
        final record = UndoRecord(
          repoPath: '/r',
          kind: kind,
          description: kind.name,
          preHead: 'pre',
          preRef: 'ref',
          postHead: 'post',
          postRef: 'ref',
        );
        final json = record.toJson();
        final restored = UndoRecord.fromJson(json);
        expect(restored, isNotNull);
        expect(restored!.kind, kind);
      }
    });

    test('stashClear round-trips stash entries', () {
      final record = UndoRecord(
        repoPath: '/r',
        kind: UndoOpKind.stashClear,
        description: 'Stash clear',
        preHead: 'pre',
        preRef: 'ref',
        postHead: 'post',
        postRef: 'ref',
        stashEntries: ['aaa WIP on main', 'bbb Fix bug'],
      );
      final json = record.toJson();
      final restored = UndoRecord.fromJson(json)!;
      expect(restored.stashEntries, ['aaa WIP on main', 'bbb Fix bug']);
    });
  });

  group('UndoCapture', () {
    test('toRecord builds an UndoRecord from captured state', () {
      const capture = UndoCapture(
        preHead: 'aaa',
        preRef: 'main',
        postHead: 'bbb',
        postRef: 'feature',
        extras: ['extra-val'],
        postExtras: ['post-val'],
      );
      final record = capture.toRecord(
        repoPath: '/r',
        kind: UndoOpKind.createBranch,
        description: 'Create branch feature',
        refName: 'feature',
        deletedOid: 'ccc',
      );
      expect(record.repoPath, '/r');
      expect(record.kind, UndoOpKind.createBranch);
      expect(record.description, 'Create branch feature');
      expect(record.preHead, 'aaa');
      expect(record.preRef, 'main');
      expect(record.postHead, 'bbb');
      expect(record.postRef, 'feature');
      expect(record.refName, 'feature');
      expect(record.deletedOid, 'ccc');
    });

    test('toRecord passes through optional fields even when null/empty', () {
      const capture = UndoCapture(
        preHead: '',
        preRef: '',
        postHead: '',
        postRef: '',
      );
      final record = capture.toRecord(
        repoPath: '/r',
        kind: UndoOpKind.commit,
        description: 'C',
      );
      expect(record.preHead, '');
      expect(record.refName, '');
    });
  });

  group('UndoStaleException', () {
    test('toString includes the record description', () {
      final record = UndoRecord(
        repoPath: '/r',
        kind: UndoOpKind.commit,
        description: 'Commit test',
        preHead: 'a',
        preRef: 'main',
        postHead: 'b',
        postRef: 'main',
      );
      final ex = UndoStaleException(record);
      expect(ex.record, record);
      expect(ex.toString(), contains('Commit test'));
    });
  });

  group('UndoDirtyException', () {
    test('toString includes the record description', () {
      final record = UndoRecord(
        repoPath: '/r',
        kind: UndoOpKind.commit,
        description: 'Commit dirty',
        preHead: 'a',
        preRef: 'main',
        postHead: 'b',
        postRef: 'main',
      );
      final ex = UndoDirtyException(record);
      expect(ex.record, record);
      expect(ex.toString(), contains('Commit dirty'));
    });
  });

  group('Redo feasibility', () {
    test('every UndoOpKind is explicitly admitted or excluded', () {
      final assessed = <UndoOpKind, RedoFeasibility>{
        for (final kind in UndoOpKind.values) kind: kind.redoFeasibility,
      };

      expect(assessed.keys, containsAll(UndoOpKind.values));
      expect(
        assessed.entries
            .where((entry) => entry.key.supportsSafeRedo)
            .map((entry) => entry.key),
        {UndoOpKind.createTag, UndoOpKind.deleteTag},
      );
      expect(
        assessed[UndoOpKind.deleteBranch],
        RedoFeasibility.branchOrCheckout,
        reason: 'another worktree can check out a branch outside a ref CAS',
      );
      expect(assessed[UndoOpKind.stashClear], RedoFeasibility.stashReflog);
      expect(
        assessed[UndoOpKind.removeFilePaths],
        RedoFeasibility.snapshotPaths,
      );
      expect(assessed[UndoOpKind.commit], RedoFeasibility.headIndexWorktree);
    });

    test(
      'a successful tag-create undo yields an absent-to-exact-OID replay',
      () {
        final undo = UndoRecord(
          repoPath: '/r',
          kind: UndoOpKind.createTag,
          description: 'Create tag v1',
          preHead: 'a',
          preRef: 'main',
          postHead: 'a',
          postRef: 'main',
          refName: 'v1',
          deletedOid: 'b' * 40,
        );

        final redo = RedoRecord.afterSuccessfulUndo(undo)!;
        expect(redo.refName, 'refs/tags/v1');
        expect(redo.expectedOid, '');
        expect(redo.replayOid, 'b' * 40);
        expect(redo.undoRecord, same(undo));
      },
    );

    test(
      'a successful tag-delete undo yields an exact-OID-to-absent replay',
      () {
        final undo = UndoRecord(
          repoPath: '/r',
          kind: UndoOpKind.deleteTag,
          description: 'Delete tag v1',
          preHead: 'a',
          preRef: 'main',
          postHead: 'a',
          postRef: 'main',
          refName: 'v1',
          deletedOid: 'b' * 40,
        );

        final redo = RedoRecord.afterSuccessfulUndo(undo)!;
        expect(redo.expectedOid, 'b' * 40);
        expect(redo.replayOid, '');
      },
    );

    test('unsupported operations generate no RedoRecord', () {
      for (final kind in UndoOpKind.values.where(
        (candidate) => !candidate.supportsSafeRedo,
      )) {
        final undo = UndoRecord(
          repoPath: '/r',
          kind: kind,
          description: kind.name,
          preHead: 'a',
          preRef: 'main',
          postHead: 'b',
          postRef: 'main',
        );
        expect(
          RedoRecord.afterSuccessfulUndo(undo),
          isNull,
          reason: '${kind.name} must stay out of the Redo UI',
        );
      }
    });
  });
}
