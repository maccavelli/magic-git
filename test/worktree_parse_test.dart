import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

/// Fixtures are the literal bytes of `git worktree list --porcelain -z` from
/// git 2.55, captured from a scratch repo built with one worktree of every
/// shape. `-z` NUL-terminates every field and separates records with an empty
/// field, so a record boundary is `\0\0`.
///
/// Deliberately NOT about the *working tree* — see `worktree_invalidation_test`
/// and `worktree_cache_staleness_test` for that, unrelated, meaning of the word.
const nul = '\u0000';

/// Builds a `-z` record from its already-formatted fields.
String rec(List<String> fields) => '${fields.map((f) => '$f$nul').join()}$nul';

void main() {
  group('parseWorktreeList', () {
    test('main worktree only', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD abc123', 'branch refs/heads/master']),
      );

      expect(wts, hasLength(1));
      expect(wts.single.path, '/repo');
      expect(wts.single.headOid, 'abc123');
      expect(wts.single.branch, 'refs/heads/master');
      expect(wts.single.isMain, isTrue);
      expect(wts.single.isPrunable, isFalse);
      expect(wts.single.isUnborn, isFalse);
      expect(wts.single.branchLabel, 'master');
      expect(wts.single.name, 'repo');
    });

    test('first record is the main worktree, the rest are not', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec(['worktree /wt-feat', 'HEAD bbb', 'branch refs/heads/feat']) +
            rec(['worktree /wt-fix', 'HEAD ccc', 'branch refs/heads/fix']),
      );

      expect(wts.map((w) => w.path), ['/repo', '/wt-feat', '/wt-fix']);
      expect(wts.map((w) => w.isMain), [true, false, false]);
      expect(wts[1].name, 'wt-feat');
      expect(wts[1].branchLabel, 'feat');
    });

    test('detached worktree has no branch', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec(['worktree /wt-det', 'HEAD c36d97d98177ffa5', 'detached']),
      );

      final det = wts[1];
      expect(det.isDetached, isTrue);
      expect(det.branch, isNull);
      expect(det.branchLabel, '(detached c36d97d)');
    });

    test('bare main repo has no HEAD line at all', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo.git', 'bare']) +
            rec(['worktree /wt', 'HEAD aaa', 'branch refs/heads/main']),
      );

      expect(wts.first.isBare, isTrue);
      expect(wts.first.headOid, isNull);
      expect(wts.first.branch, isNull);
      expect(wts.first.isDetached, isFalse);
      expect(wts.first.branchLabel, 'bare');
      // No HEAD line means a null OID — the same signal an unborn worktree
      // gives. Bare is not unborn; isUnborn must tell them apart.
      expect(wts.first.isUnborn, isFalse);
    });

    test('locked without a reason is a bare flag', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec([
              'worktree /wt-lock2',
              'HEAD bbb',
              'branch refs/heads/lock2',
              'locked',
            ]),
      );

      expect(wts[1].isLocked, isTrue);
      // Empty, not null — which is exactly why `lockReason` cannot double as
      // the locked flag.
      expect(wts[1].lockReason, isEmpty);
    });

    test('locked with a reason keeps the reason', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec([
              'worktree /wt-locked',
              'HEAD bbb',
              'branch refs/heads/lockedbr',
              'locked usb drive',
            ]),
      );

      expect(wts[1].isLocked, isTrue);
      expect(wts[1].lockReason, 'usb drive');
    });

    test('prunable worktree carries git\'s reason', () {
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec([
              'worktree /wt-gone',
              'HEAD bbb',
              'branch refs/heads/gonebr',
              'prunable gitdir file points to non-existent location',
            ]),
      );

      expect(wts[1].isPrunable, isTrue);
      expect(
        wts[1].prunableReason,
        'gitdir file points to non-existent location',
      );
      // The main worktree is never prunable, and git never reports it as such.
      expect(wts.first.isPrunable, isFalse);
    });

    test('unborn (--orphan) HEAD is the null OID but STILL has a branch', () {
      // The trap: `--orphan` emits neither `detached` nor a missing branch
      // line — it emits a real branch with an all-zero OID. So the null OID is
      // the only signal, and any "branch xor detached" assumption is wrong.
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec([
              'worktree /wt-orphan',
              'HEAD 0000000000000000000000000000000000000000',
              'branch refs/heads/wt-orphan',
            ]),
      );

      final orphan = wts[1];
      expect(orphan.isUnborn, isTrue);
      expect(orphan.headOid, isNull);
      expect(orphan.isDetached, isFalse);
      expect(orphan.branch, 'refs/heads/wt-orphan');
      expect(orphan.branchLabel, 'wt-orphan');
    });

    test('a path containing a space or newline survives -z', () {
      // The whole reason `-z` is mandatory: git does not quote paths in the
      // newline porcelain form, so this record is unparseable without it.
      final wts = parseWorktreeList(
        rec(['worktree /repo', 'HEAD aaa', 'branch refs/heads/master']) +
            rec([
              'worktree /wt/my project\nweird',
              'HEAD bbb',
              'branch refs/heads/x',
            ]),
      );

      expect(wts, hasLength(2));
      expect(wts[1].path, '/wt/my project\nweird');
      expect(wts[1].branch, 'refs/heads/x');
    });

    test('empty output yields no worktrees', () {
      expect(parseWorktreeList(''), isEmpty);
      expect(parseWorktreeList(nul), isEmpty);
    });
  });

  group('RepoLayout', () {
    test('main worktree: git dir equals common dir', () {
      const layout = RepoLayout(
        toplevel: '/repo',
        gitDir: '/repo/.git',
        gitCommonDir: '/repo/.git',
      );

      expect(layout.isLinkedWorktree, isFalse);
      expect(layout.isSubmodule, isFalse);
      expect(layout.mainWorktreePath, '/repo');
    });

    test('linked worktree: git dir is the admin dir under the main repo', () {
      const layout = RepoLayout(
        toplevel: '/wt-feat',
        gitDir: '/repo/.git/worktrees/wt-feat',
        gitCommonDir: '/repo/.git',
      );

      expect(layout.isLinkedWorktree, isTrue);
      expect(layout.isSubmodule, isFalse);
      // The point of the whole feature: from a linked worktree we can find the
      // main repo, whose grant we also need under the sandbox.
      expect(layout.mainWorktreePath, '/repo');
    });

    test('submodule is NOT a linked worktree despite also using a gitfile', () {
      // A submodule's `.git` is a file too, so "is .git a file" would
      // misclassify it. Its git dir and common dir are equal, which is the only
      // thing that separates the two cases.
      const layout = RepoLayout(
        toplevel: '/super/sub',
        gitDir: '/super/.git/modules/sub',
        gitCommonDir: '/super/.git/modules/sub',
      );

      expect(layout.isLinkedWorktree, isFalse);
      expect(layout.isSubmodule, isTrue);
    });

    test('mainWorktreePath is null when the common dir is not a .git', () {
      // Bare repo / --separate-git-dir: deriving the main worktree by chopping
      // `/.git` is wrong, so it declines to guess and callers fall back to the
      // first record of `worktree list`.
      const layout = RepoLayout(
        toplevel: '/wt',
        gitDir: '/srv/repo.git/worktrees/wt',
        gitCommonDir: '/srv/repo.git',
      );

      expect(layout.isLinkedWorktree, isTrue);
      expect(layout.mainWorktreePath, isNull);
    });
  });

  group('GitRef.worktreePath', () {
    // `%(worktreepath)` is field index 6, appended after `%(*objectname)` so the
    // existing field indices are untouched.
    List<GitRef> parse(List<List<String>> rows) => parseRefs(
      rows.map((r) => r.join(GitService.fieldSep)).join('\n'),
      GitService.fieldSep,
    );

    test('populated for a branch checked out in a linked worktree', () {
      final refs = parse([
        [' ', 'refs/heads/feat', 'bbb', '', 'subject', '', '/wt-feat'],
      ]);

      expect(refs.single.worktreePath, '/wt-feat');
      expect(refs.single.isHead, isFalse);
    });

    test('populated for the CURRENT worktree too — git\'s docs are wrong', () {
      // git documents `%(worktreepath)` as being set only for *linked*
      // worktrees. It is in fact set for the current/main one as well, so a
      // non-null value alone does not mean "checked out somewhere else".
      final refs = parse([
        ['*', 'refs/heads/master', 'aaa', '', 'subject', '', '/repo'],
      ]);

      expect(refs.single.isHead, isTrue);
      expect(refs.single.worktreePath, '/repo');
    });

    test('null for a branch that is not checked out anywhere', () {
      final refs = parse([
        [' ', 'refs/heads/idle', 'ccc', '', 'subject', '', ''],
      ]);

      expect(refs.single.worktreePath, isNull);
    });

    test('a git older than 2.23 echoes the atom back, which is ignored', () {
      // Pre-2.23 git doesn't know `%(worktreepath)` and emits it verbatim.
      // Requiring a leading `/` rejects that without a version probe.
      final refs = parse([
        [' ', 'refs/heads/old', 'ddd', '', 'subject', '', '%(worktreepath)'],
      ]);

      expect(refs.single.worktreePath, isNull);
    });

    test('the pre-existing fields still parse with the new column present', () {
      final refs = parse([
        ['*', 'refs/heads/main', 'aaa', 'origin/main', 'hello', '', '/repo'],
        [' ', 'refs/tags/v1', 'ttt', '', 'tag msg', 'ccc', ''],
      ]);

      expect(refs[0].upstream, 'origin/main');
      expect(refs[0].subject, 'hello');
      expect(refs[0].peeledOid, isNull);
      expect(refs[1].isTag, isTrue);
      expect(refs[1].peeledOid, 'ccc');
      expect(refs[1].commitOid, 'ccc');
    });
  });
}
