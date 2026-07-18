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

const _remoteBranch = DragRef(
  GitRef(
    name: 'refs/remotes/origin/feature',
    oid: 'a1b2c3d4e5f6',
    isHead: false,
    subject: 's',
  ),
);

const _stash = DragStash(
  GitStash(
    index: 0,
    oid: 'deadbeefdeadbeef',
    branch: 'main',
    message: 'WIP on main: 1234567 in-progress work',
  ),
);

const _files = DragFiles(['lib/a.dart', 'lib/b.dart']);

void main() {
  test('a commit dropped on Branches offers "New branch"', () {
    expect(canDrop(_commit, DropZoneId.branches), isTrue);
    expect(dropVerb(_commit, DropZoneId.branches), 'New branch');
  });

  test('a branch or a commit dropped on Worktrees offers "New worktree"', () {
    expect(canDrop(_branch, DropZoneId.worktrees), isTrue);
    expect(dropVerb(_branch, DropZoneId.worktrees), 'New worktree');
    expect(canDrop(_commit, DropZoneId.worktrees), isTrue);
    expect(dropVerb(_commit, DropZoneId.worktrees), 'New worktree');
  });

  test('a commit dropped on Repository cherry-picks; a branch does not', () {
    expect(canDrop(_commit, DropZoneId.repository), isTrue);
    expect(dropVerb(_commit, DropZoneId.repository), 'Cherry-pick');
    expect(canDrop(_branch, DropZoneId.repository), isFalse);
  });

  test('a local branch dropped on Forge offers "New PR / MR"', () {
    expect(canDrop(_branch, DropZoneId.forge), isTrue);
    expect(dropVerb(_branch, DropZoneId.forge), 'New PR / MR');
    // A remote-tracking ref can't be a PR/MR source, and a commit isn't a branch.
    expect(canDrop(_remoteBranch, DropZoneId.forge), isFalse);
    expect(canDrop(_commit, DropZoneId.forge), isFalse);
  });

  test('a stash dropped on Repository offers apply and pop', () {
    expect(canDrop(_stash, DropZoneId.repository), isTrue);
    // Two actions -> the rail shows the primary verb (Apply); the menu on drop
    // lists both. A stash isn't a valid payload for the other zones.
    expect(dropVerb(_stash, DropZoneId.repository), 'Apply stash');
    expect(canDrop(_stash, DropZoneId.stashes), isFalse);
    expect(canDrop(_stash, DropZoneId.branches), isFalse);
  });

  test('files dropped on Stashes offer a partial stash', () {
    expect(canDrop(_files, DropZoneId.stashes), isTrue);
    expect(dropVerb(_files, DropZoneId.stashes), 'Stash files');
    // Files only make sense as a stash source, and only when non-empty.
    expect(canDrop(_files, DropZoneId.repository), isFalse);
    expect(canDrop(_files, DropZoneId.branches), isFalse);
    expect(canDrop(const DragFiles([]), DropZoneId.stashes), isFalse);
  });

  test('payloads are rejected by zones with no action for them', () {
    // branch -> Branches is a future phase, not this cut.
    expect(canDrop(_branch, DropZoneId.branches), isFalse);
    // Zones with no drop actions at all reject the commit/branch payloads.
    // (Stashes now accepts DragFiles, but never a commit or a branch.)
    for (final zone in const [
      DropZoneId.history,
      DropZoneId.stashes,
    ]) {
      expect(canDrop(_commit, zone), isFalse, reason: '$zone');
      expect(canDrop(_branch, zone), isFalse, reason: '$zone');
      expect(dropVerb(_commit, zone), isNull);
    }
  });

  test('a zone id maps to its sidebar page index', () {
    expect(DropZoneId.repository.pageIndex, 0);
    expect(DropZoneId.branches.pageIndex, 2);
    expect(DropZoneId.worktrees.pageIndex, 5);
  });
}
