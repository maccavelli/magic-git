// Unit tests for the repository file-tree model. Structure (buildRepoTree) is
// now status-free; change/dirty coloring lives in RepoStatusOverlay; and
// structureSignature gates when the structure must be re-fetched.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/repo_tree.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';

RepoNode? _find(RepoNode node, String path) {
  if (node.path == path) return node;
  for (final c in node.children) {
    final r = _find(c, path);
    if (r != null) return r;
  }
  return null;
}

GitStatus _status(List<GitFileStatus> files) =>
    GitStatus(branch: const GitBranchInfo(), files: files);

void main() {
  test('repoDirtyIndex marks ancestors of changes and untracked dirs', () {
    final status = _status(const [
      GitFileStatus(path: 'src/util/b.dart', statusX: '.', statusY: 'M'),
      GitFileStatus(path: 'src/new.txt', statusX: '?', statusY: '?'),
      GitFileStatus(path: 'scratch/', statusX: '?', statusY: '?'),
    ]);

    final index = repoDirtyIndex(status);

    expect(index.dirtyDirs, containsAll(['src', 'src/util', 'scratch']));
    expect(index.dirtyDirs, isNot(contains('docs')));
    // Individual changed/untracked files are mapped; the collapsed dir is not.
    expect(index.changed.keys, containsAll(['src/util/b.dart', 'src/new.txt']));
    expect(index.changed.containsKey('scratch/'), isFalse);
    // The collapsed untracked directory is recorded for per-file synthesis.
    expect(index.untrackedDirs, contains('scratch'));
  });

  test('RepoStatusOverlay colors dirs and synthesizes ? under untracked dirs', () {
    final overlay = RepoStatusOverlay.fromStatus(
      _status(const [
        GitFileStatus(path: 'src/util/b.dart', statusX: '.', statusY: 'M'),
        GitFileStatus(path: 'scratch/', statusX: '?', statusY: '?'),
      ]),
    );

    // Ancestors of a change are dirty; unrelated dirs are not.
    expect(overlay.isDirtyDir('src'), isTrue);
    expect(overlay.isDirtyDir('src/util'), isTrue);
    expect(overlay.isDirtyDir('docs'), isFalse);

    // A reported change keeps its exact status.
    expect(overlay.statusFor('src/util/b.dart')?.isUnstaged, isTrue);
    // Files beneath a collapsed untracked dir are synthesized as untracked...
    expect(overlay.statusFor('scratch/a.txt')?.isUntracked, isTrue);
    expect(overlay.statusFor('scratch/deep/b.txt')?.isUntracked, isTrue);
    // ...while an unrelated clean file has no status.
    expect(overlay.statusFor('src/clean.dart'), isNull);
  });

  test('buildRepoTree nests paths and collapses wholly-ignored dirs', () {
    final root = buildRepoTree(
      files: [
        'src/a.dart',
        'src/util/b.dart',
        'src/new.txt',
        'docs/readme.md',
        'build/keep.txt',
      ],
      // build/ has an ignored file; node_modules/ is a wholly-ignored dir.
      ignored: ['node_modules/', 'build/out.log'],
    );

    // Nesting.
    expect(_find(root, 'src')!.isDir, isTrue);
    expect(_find(root, 'src/util/b.dart')!.isDir, isFalse);

    // A dir that only holds an *ignored* file is itself not ignored.
    final build = _find(root, 'build')!;
    expect(build.isDir, isTrue);
    expect(build.ignored, isFalse);
    expect(_find(root, 'build/out.log')!.ignored, isTrue);

    // Wholly-ignored dir is a collapsed lazy node with no eager children.
    final nm = _find(root, 'node_modules')!;
    expect(nm.isDir, isTrue);
    expect(nm.ignored, isTrue);
    expect(nm.lazy, isTrue);
    expect(nm.children, isEmpty);

    // Children are sorted directories-first.
    final topDirs = root.children.where((c) => c.isDir).map((c) => c.name);
    final topFiles = root.children.where((c) => !c.isDir).map((c) => c.name);
    expect(root.children.take(topDirs.length).every((c) => c.isDir), isTrue);
    expect(topFiles, isEmpty); // every top-level entry here is a directory
  });

  test('structureSignature reacts to add/remove/rename but not content edits', () {
    final clean = _status(const []);
    // A pure modification doesn't change the tree's shape.
    final edited = _status(const [
      GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M'),
    ]);
    expect(structureSignature(edited), structureSignature(clean));

    // Two different modifications still agree (both add no shape).
    final edited2 = _status(const [
      GitFileStatus(path: 'b.dart', statusX: '.', statusY: 'M'),
    ]);
    expect(structureSignature(edited2), structureSignature(edited));

    // New untracked file, staged addition, and deletion each change the shape.
    for (final f in const [
      GitFileStatus(path: 'new.txt', statusX: '?', statusY: '?'),
      GitFileStatus(path: 'x.dart', statusX: 'A', statusY: '.'),
      GitFileStatus(path: 'x.dart', statusX: 'D', statusY: '.'),
    ]) {
      expect(
        structureSignature(_status([f])),
        isNot(structureSignature(clean)),
        reason: 'status ${f.statusX}${f.statusY} ${f.path} should move the hash',
      );
    }

    // A rename (with its old path) differs from the same new path added alone.
    final renamed = _status(const [
      GitFileStatus(
        path: 'lib/new.dart',
        oldPath: 'lib/old.dart',
        statusX: 'R',
        statusY: '.',
      ),
    ]);
    final addedOnly = _status(const [
      GitFileStatus(path: 'lib/new.dart', statusX: 'A', statusY: '.'),
    ]);
    expect(structureSignature(renamed), isNot(structureSignature(addedOnly)));
  });

  test(
    'two different partially-staged files must not collide '
    '(regression: staged+unstaged double-counting an XY="AM" file used to '
    'XOR-cancel its contribution to a fixed, path-independent value)',
    () {
      // XY="AM" — staged as Added, then edited again in the worktree (an
      // entirely ordinary `git add file; edit file further` workflow). This
      // single GitFileStatus satisfies both isStaged and isUnstaged, so it
      // appears in *both* status.staged and status.unstaged. Before the fix,
      // every such status — regardless of the file's path — collapsed to the
      // exact same signature: the duplicated key always self-cancels under
      // XOR (acc = h ^ h = 0) while `count` always double-increments the same
      // way, so any two different single-partially-staged-file statuses were
      // indistinguishable, silently skipping a needed tree rebuild.
      final a = _status(const [
        GitFileStatus(path: 'a.dart', statusX: 'A', statusY: 'M'),
      ]);
      final b = _status(const [
        GitFileStatus(path: 'b.dart', statusX: 'A', statusY: 'M'),
      ]);
      expect(structureSignature(a), isNot(structureSignature(b)));
      expect(structureSignature(a), isNot(structureSignature(_status(const []))));
    },
  );
}
