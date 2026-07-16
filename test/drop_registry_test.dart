// The drop registry: the canonical (payload, zone) -> actions table that powers
// dragging panel items onto nav-rail tabs. Pure resolution logic — no widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';

const _commit = DragCommit(
  GitCommit(
    hash: 'a1b2c3d4e5f6',
    shortHash: 'a1b2c3d',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-16T10:00',
    parents: [],
    subject: 'a change',
  ),
);

const _branch = DragRef(
  GitRef(
    name: 'refs/heads/feature',
    oid: 'a1b2c3d4e5f6',
    isHead: false,
    subject: 's',
  ),
);

void main() {
  test('a commit dropped on Branches offers "New branch"', () {
    expect(canDrop(_commit, DropZoneId.branches), isTrue);
    expect(dropVerb(_commit, DropZoneId.branches), 'New branch');
  });

  test('a branch dropped on Worktrees offers "New worktree"', () {
    expect(canDrop(_branch, DropZoneId.worktrees), isTrue);
    expect(dropVerb(_branch, DropZoneId.worktrees), 'New worktree');
  });

  test('payloads are rejected by zones with no action for them', () {
    // Commit -> Worktrees and branch -> Branches are future phases, not this cut.
    expect(canDrop(_commit, DropZoneId.worktrees), isFalse);
    expect(canDrop(_branch, DropZoneId.branches), isFalse);
    // And zones with no drop actions at all.
    for (final zone in const [
      DropZoneId.repository,
      DropZoneId.history,
      DropZoneId.stashes,
      DropZoneId.forge,
      DropZoneId.project,
    ]) {
      expect(canDrop(_commit, zone), isFalse, reason: '$zone');
      expect(canDrop(_branch, zone), isFalse, reason: '$zone');
      expect(dropVerb(_commit, zone), isNull);
    }
  });

  test('a zone id maps to its sidebar page index', () {
    expect(DropZoneId.repository.pageIndex, 0);
    expect(DropZoneId.branches.pageIndex, 2);
    expect(DropZoneId.worktrees.pageIndex, 6);
  });
}
