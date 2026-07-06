import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Captures the argument vectors passed to the executor without touching SSH.
class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<Map<String, String>?> envs = [];
  final List<String?> stdins = [];

  /// Result for the next call. When [results] is non-empty it is consumed in
  /// order (for multi-call flows like loginWithToken); otherwise [next] is used.
  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );
  final List<SSHCommandResult> results = [];

  _FakeExecutor() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
  }) async {
    calls.add(gitArgs);
    envs.add(extraEnv);
    stdins.add(stdin);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

void main() {
  group('GitService mutations build correct argv', () {
    late _FakeExecutor exec;
    late GitService git;

    setUp(() {
      exec = _FakeExecutor();
      git = GitService(exec);
    });

    test('stage', () async {
      await git.stage('/repo', 'lib/main.dart');
      expect(exec.calls.single, ['git', 'add', '--', 'lib/main.dart']);
    });

    test('unstage uses restore --staged', () async {
      await git.unstage('/repo', 'lib/main.dart');
      expect(exec.calls.single, [
        'git',
        'restore',
        '--staged',
        '--',
        'lib/main.dart',
      ]);
    });

    test('commit passes --no-gpg-sign and the message as one arg', () async {
      await git.commit('/repo', message: 'fix: a thing');
      expect(exec.calls.single, [
        'git',
        'commit',
        '--no-gpg-sign',
        '-m',
        'fix: a thing',
      ]);
    });

    test('commit with no message omits -m (lets the hook write it)', () async {
      await git.commit('/repo');
      expect(exec.calls.single, ['git', 'commit', '--no-gpg-sign']);
      exec.calls.clear();
      await git.commit('/repo', message: '   ');
      expect(exec.calls.single, ['git', 'commit', '--no-gpg-sign']);
    });

    test('checkout', () async {
      await git.checkout('/repo', 'feature');
      expect(exec.calls.single, [
        'git',
        'checkout',
        '--end-of-options',
        'feature',
      ]);
    });

    test('createBranch checks out by default', () async {
      await git.createBranch('/repo', 'feat');
      expect(exec.calls.single, [
        'git',
        'checkout',
        '-b',
        '--end-of-options',
        'feat',
      ]);
    });

    test('createBranch without checkout uses git branch', () async {
      await git.createBranch('/repo', 'feat', checkout: false);
      expect(exec.calls.single, [
        'git',
        'branch',
        '--end-of-options',
        'feat',
      ]);
    });

    test('deleteBranch force uses -D', () async {
      await git.deleteBranch('/repo', 'old', force: true);
      expect(exec.calls.single, [
        'git',
        'branch',
        '-D',
        '--end-of-options',
        'old',
      ]);
    });

    test('discard restores the working tree path', () async {
      await git.discard('/repo', 'a.dart');
      expect(exec.calls.single, ['git', 'restore', '--', 'a.dart']);
    });

    test('readFile cats the path directly, guarded by --', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'hello\n',
        stderr: '',
      );
      final content = await git.readFile('/repo', 'lib/main.dart');
      expect(exec.calls.single, ['cat', '--', 'lib/main.dart']);
      expect(content, 'hello\n');
    });

    test('readFile throws GitException on a failed read', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'cat: nope: No such file or directory',
      );
      await expectLater(
        git.readFile('/repo', 'nope'),
        throwsA(isA<GitException>()),
      );
    });

    test('discardStaged restores both index and worktree from HEAD', () async {
      await git.discardStaged('/repo', 'a.dart');
      expect(exec.calls.single, [
        'git',
        'restore',
        '--staged',
        '--worktree',
        '--source=HEAD',
        '--',
        'a.dart',
      ]);
    });

    test('addToGitignore appends via a dedup-checked shell script', () async {
      await git.addToGitignore('/repo', 'build/');
      final call = exec.calls.single;
      expect(call[0], 'sh');
      expect(call[1], '-c');
      final script = call[2];
      expect(script, contains("touch \"\$f\""));
      expect(script, contains("grep -qxF -- 'build/'"));
      expect(script, contains("printf '%s\\n' 'build/'"));
    });

    test('stageMany/unstageMany/discardMany/removeUntrackedFilesMany/'
        'discardStagedMany/addToGitignoreMany cover the whole list in one '
        'invocation', () async {
      final paths = ['a.dart', 'b.dart'];

      await git.stageMany('/repo', paths);
      expect(exec.calls.single, ['git', 'add', '--', 'a.dart', 'b.dart']);
      exec.calls.clear();

      await git.unstageMany('/repo', paths);
      expect(exec.calls.single, [
        'git',
        'restore',
        '--staged',
        '--',
        'a.dart',
        'b.dart',
      ]);
      exec.calls.clear();

      await git.discardMany('/repo', paths);
      expect(exec.calls.single, [
        'git',
        'restore',
        '--',
        'a.dart',
        'b.dart',
      ]);
      exec.calls.clear();

      await git.removeUntrackedFilesMany('/repo', paths);
      expect(exec.calls.single, [
        'git',
        'clean',
        '-f',
        '--',
        'a.dart',
        'b.dart',
      ]);
      exec.calls.clear();

      await git.discardStagedMany('/repo', paths);
      expect(exec.calls.single, [
        'git',
        'restore',
        '--staged',
        '--worktree',
        '--source=HEAD',
        '--',
        'a.dart',
        'b.dart',
      ]);
      exec.calls.clear();

      await git.addToGitignoreMany('/repo', paths);
      final script = exec.calls.single[2];
      expect(script, contains("grep -qxF -- 'a.dart'"));
      expect(script, contains("grep -qxF -- 'b.dart'"));
    });

    test('diffFile applies hide-whitespace and expand-context options', () async {
      await git.diffFile(
        '/repo',
        path: 'a.dart',
        staged: true,
        ignoreWhitespace: true,
        context: 25,
      );
      expect(exec.calls.single, [
        'git',
        'diff',
        '--no-color',
        '--cached',
        '-w',
        '-U25',
        '--',
        'a.dart',
      ]);
    });

    test('diffFile with defaults omits -w and -U', () async {
      await git.diffFile('/repo', path: 'a.dart', staged: false);
      expect(exec.calls.single, ['git', 'diff', '--no-color', '--', 'a.dart']);
    });

    test('diffRange diffs a ref range for the MR preview', () async {
      await git.diffRange('/repo', 'main...feat');
      expect(exec.calls.single, [
        'git',
        'diff',
        '--no-color',
        '--end-of-options',
        'main...feat',
      ]);
    });

    test('applyPatch stages a hunk via git apply --cached (stdin patch)', () async {
      await git.applyPatch('/repo', 'PATCH', cached: true, reverse: false);
      expect(exec.calls.single, [
        'git',
        'apply',
        '--cached',
        '--recount',
        '--whitespace=nowarn',
        '-',
      ]);
      expect(exec.stdins.single, 'PATCH');
    });

    test('applyPatch reverse (unstage / discard) adds -R', () async {
      await git.applyPatch('/repo', 'P', cached: true, reverse: true);
      expect(exec.calls.single, [
        'git',
        'apply',
        '--cached',
        '-R',
        '--recount',
        '--whitespace=nowarn',
        '-',
      ]);
      exec.calls.clear();
      await git.applyPatch('/repo', 'P', cached: false, reverse: true);
      expect(exec.calls.single, [
        'git',
        'apply',
        '-R',
        '--recount',
        '--whitespace=nowarn',
        '-',
      ]);
    });

    test('fetch / pull / push', () async {
      await git.fetch('/repo');
      await git.pull('/repo');
      await git.push('/repo');
      expect(exec.calls[0], ['git', 'fetch', '--all', '--prune']);
      expect(exec.calls[1], ['git', 'pull', '--ff-only']);
      expect(exec.calls[2], ['git', 'push']);
    });

    test('pull mode maps to the right flag', () async {
      await git.pull('/repo', mode: PullMode.rebase);
      await git.pull('/repo', mode: PullMode.merge);
      await git.pull('/repo', remote: 'origin', branch: 'main');
      expect(exec.calls[0], ['git', 'pull', '--rebase']);
      expect(exec.calls[1], ['git', 'pull', '--no-rebase']);
      expect(exec.calls[2], [
        'git',
        'pull',
        '--ff-only',
        '--end-of-options',
        'origin',
        'main',
      ]);
    });

    test('pull omits the branch when no remote is given', () async {
      await git.pull('/repo', branch: 'main');
      expect(exec.calls.single, ['git', 'pull', '--ff-only']);
    });

    test('push force / upstream / tags flags', () async {
      await git.push('/repo', force: PushForce.withLease);
      await git.push('/repo', force: PushForce.force);
      await git.push('/repo', setUpstream: true, followTags: true);
      await git.push('/repo', remote: 'origin', branch: 'feat');
      expect(exec.calls[0], ['git', 'push', '--force-with-lease']);
      expect(exec.calls[1], ['git', 'push', '--force']);
      expect(exec.calls[2], ['git', 'push', '-u', '--follow-tags']);
      expect(exec.calls[3], [
        'git',
        'push',
        '--end-of-options',
        'origin',
        'feat',
      ]);
    });

    test('createTag: lightweight vs annotated', () async {
      await git.createTag('/repo', 'v1.0.0');
      expect(exec.calls.single, [
        'git',
        'tag',
        '--end-of-options',
        'v1.0.0',
        'HEAD',
      ]);
      exec.calls.clear();
      await git.createTag('/repo', 'v1.0.0', message: 'release', ref: 'abc123');
      expect(exec.calls.single, [
        'git',
        'tag',
        '-a',
        '-m',
        'release',
        '--end-of-options',
        'v1.0.0',
        'abc123',
      ]);
    });

    test('committer identity injects -c flags on an annotated tag', () async {
      // An annotated tag is a real object (like a commit) and needs an
      // author identity on a host with none configured.
      final idGit = GitService(
        exec,
        committerName: 'Jane Dev',
        committerEmail: 'jane@example.com',
      );
      await idGit.createTag('/repo', 'v1.0.0', message: 'release');
      expect(exec.calls.single, [
        'git',
        '-c',
        'user.name=Jane Dev',
        '-c',
        'user.email=jane@example.com',
        'tag',
        '-a',
        '-m',
        'release',
        '--end-of-options',
        'v1.0.0',
        'HEAD',
      ]);
    });

    test('deleteTag / pushTag', () async {
      await git.deleteTag('/repo', 'v1.0.0');
      await git.pushTag('/repo', 'v1.0.0');
      expect(exec.calls[0], [
        'git',
        'tag',
        '-d',
        '--end-of-options',
        'v1.0.0',
      ]);
      expect(exec.calls[1], [
        'git',
        'push',
        '--end-of-options',
        'origin',
        'refs/tags/v1.0.0',
      ]);
    });

    test('cherryPick: plain vs merge mainline, and abort', () async {
      await git.cherryPick('/repo', 'abc');
      expect(exec.calls.single, [
        'git',
        'cherry-pick',
        '--end-of-options',
        'abc',
      ]);
      exec.calls.clear();
      await git.cherryPick('/repo', 'abc', mainline: 1);
      expect(exec.calls.single, [
        'git',
        'cherry-pick',
        '-m',
        '1',
        '--end-of-options',
        'abc',
      ]);
      exec.calls.clear();
      await git.cherryPickAbort('/repo');
      expect(exec.calls.single, ['git', 'cherry-pick', '--abort']);
    });

    test('revert: no-edit, merge mainline, and abort', () async {
      await git.revert('/repo', 'abc');
      expect(exec.calls.single, [
        'git',
        'revert',
        '--no-edit',
        '--end-of-options',
        'abc',
      ]);
      exec.calls.clear();
      await git.revert('/repo', 'abc', mainline: 2);
      expect(exec.calls.single, [
        'git',
        'revert',
        '--no-edit',
        '-m',
        '2',
        '--end-of-options',
        'abc',
      ]);
      exec.calls.clear();
      await git.revertAbort('/repo');
      expect(exec.calls.single, ['git', 'revert', '--abort']);
    });

    test('reset maps each mode', () async {
      await git.reset('/repo', 'abc', mode: ResetMode.soft);
      await git.reset('/repo', 'abc', mode: ResetMode.mixed);
      await git.reset('/repo', 'abc', mode: ResetMode.hard);
      expect(exec.calls[0], [
        'git',
        'reset',
        '--soft',
        '--end-of-options',
        'abc',
      ]);
      expect(exec.calls[1], [
        'git',
        'reset',
        '--mixed',
        '--end-of-options',
        'abc',
      ]);
      expect(exec.calls[2], [
        'git',
        'reset',
        '--hard',
        '--end-of-options',
        'abc',
      ]);
    });

    test('branchFrom roots the branch at a start point', () async {
      await git.branchFrom('/repo', 'feat', 'abc');
      expect(exec.calls.single, [
        'git',
        'checkout',
        '-b',
        '--end-of-options',
        'feat',
        'abc',
      ]);
      exec.calls.clear();
      await git.branchFrom('/repo', 'feat', 'abc', checkout: false);
      expect(exec.calls.single, [
        'git',
        'branch',
        '--end-of-options',
        'feat',
        'abc',
      ]);
    });

    test('amendCommit: keep message vs rewrite', () async {
      await git.amendCommit('/repo');
      expect(exec.calls.single, [
        'git',
        'commit',
        '--amend',
        '--no-gpg-sign',
        '--no-edit',
      ]);
      exec.calls.clear();
      await git.amendCommit('/repo', message: 'new subject');
      expect(exec.calls.single, [
        'git',
        'commit',
        '--amend',
        '--no-gpg-sign',
        '-m',
        'new subject',
      ]);
    });

    test('pendingOp detects an in-progress operation from the git dir', () async {
      // pendingOp is bundled with status/refs into one combined `sh -c`
      // round trip (see GitService._fetchSnapshot) — the operation name is
      // the last of the sep-delimited sections (sep matches
      // GitService._snapshotSep: STX-wrapped "RMGSNAP").
      const sep = 'RMGSNAP';
      String combined(String op) => '$sep' '0$sep' '$sep' '0$sep' '$op\n';
      exec.results.add(
        SSHCommandResult(exitCode: 0, stdout: combined('cherry-pick'), stderr: ''),
      );
      expect(await git.pendingOp('/repo'), PendingOp.cherryPick);

      exec.results.add(
        SSHCommandResult(exitCode: 0, stdout: combined('none'), stderr: ''),
      );
      expect(await git.pendingOp('/repo'), PendingOp.none);
    });

    test('merge builds the right argv per mode', () async {
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.merge('/repo', 'feature', mode: MergeMode.noFf);
      expect(exec.calls.single, [
        'git',
        'merge',
        '--no-edit',
        '--no-ff',
        '--end-of-options',
        'feature',
      ]);
      exec.calls.clear();
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.merge('/repo', 'feature', mode: MergeMode.squash);
      expect(exec.calls.single, [
        'git',
        'merge',
        '--no-edit',
        '--squash',
        '--end-of-options',
        'feature',
      ]);
    });

    test('log applies grep/author/all/follow/path filters', () async {
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.log('/repo', grep: 'fix bug', author: 'jane', all: true);
      final args = exec.calls.single;
      expect(args, containsAllInOrder(['--grep=fix bug', '-i']));
      expect(args, contains('--author=jane'));
      expect(args, contains('--all'));
      expect(args, isNot(contains('HEAD')));
      // Required by CommitGraph.build's lane algorithm, which assumes a
      // commit never appears before any of its parents — especially
      // important for this --all (multi-branch) call, where date order can
      // otherwise interleave commits out of ancestry order.
      expect(args, contains('--topo-order'));

      exec.calls.clear();
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.log('/repo', path: 'lib/x.dart', follow: true);
      final a2 = exec.calls.single;
      expect(a2, contains('--follow'));
      expect(a2, containsAllInOrder(['--', 'lib/x.dart']));
      expect(a2, contains('HEAD'));
      expect(a2, contains('--topo-order'));
    });

    test('log hardening: --no-show-signature, --end-of-options, guarded --follow', () async {
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.log('/repo');
      final bare = exec.calls.single;
      // Suppresses interleaved gpg lines under a remote log.showSignature=true.
      expect(bare, contains('--no-show-signature'));
      // A leading-dash ref can't be parsed as an option.
      expect(bare, containsAllInOrder(['--end-of-options', 'HEAD']));

      // --follow with no pathspec is a fatal git error — it must be omitted.
      exec.calls.clear();
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.log('/repo', follow: true);
      expect(exec.calls.single, isNot(contains('--follow')));

      // git also rejects --follow together with --all.
      exec.calls.clear();
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.log('/repo', all: true, follow: true, path: 'lib/x.dart');
      expect(exec.calls.single, isNot(contains('--follow')));
    });

    test('rebaseInteractive pipes the todo and omits dropped steps', () async {
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.rebaseInteractive('/repo', 'base123', const [
        RebaseStep(RebaseAction.pick, 'aaa'),
        RebaseStep(RebaseAction.squash, 'bbb'),
        RebaseStep(RebaseAction.drop, 'ccc'),
      ]);
      final call = exec.calls.single;
      expect(call[0], 'sh');
      expect(call[1], '-c');
      expect(call[2], contains('rebase -i'));
      expect(call[2], contains("'base123'"));
      // The plan is piped on stdin; dropped commits are omitted.
      expect(exec.stdins.single, 'pick aaa\nsquash bbb');
    });

    test('committer identity injects -c flags on commit', () async {
      final idGit = GitService(
        exec,
        committerName: 'Jane Dev',
        committerEmail: 'jane@example.com',
      );
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await idGit.commit('/repo', message: 'hi');
      expect(exec.calls.single, [
        'git',
        '-c',
        'user.name=Jane Dev',
        '-c',
        'user.email=jane@example.com',
        'commit',
        '--no-gpg-sign',
        '-m',
        'hi',
      ]);
    });

    test('stashPush with and without a message', () async {
      await git.stashPush('/repo');
      expect(exec.calls.single, ['git', 'stash', 'push']);
      exec.calls.clear();
      await git.stashPush('/repo', message: 'wip');
      expect(exec.calls.single, ['git', 'stash', 'push', '-m', 'wip']);
    });

    test('committer identity injects -c flags on stashPush', () async {
      // `git stash push` creates real commit objects under the hood and
      // needs an author identity on a host with none configured.
      final idGit = GitService(
        exec,
        committerName: 'Jane Dev',
        committerEmail: 'jane@example.com',
      );
      await idGit.stashPush('/repo', message: 'wip');
      expect(exec.calls.single, [
        'git',
        '-c',
        'user.name=Jane Dev',
        '-c',
        'user.email=jane@example.com',
        'stash',
        'push',
        '-m',
        'wip',
      ]);
    });

    test('showCommit: bare vs path-scoped', () async {
      await git.showCommit('/repo', 'abc123');
      expect(exec.calls.single, [
        'git',
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'show',
        '--no-color',
        '--no-show-signature',
        '--end-of-options',
        'abc123',
      ]);
      exec.calls.clear();
      await git.showCommit('/repo', 'abc123', path: 'lib/a.dart');
      expect(exec.calls.single, [
        'git',
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'show',
        '--no-color',
        '--no-show-signature',
        '--end-of-options',
        'abc123',
        '--',
        'lib/a.dart',
      ]);
    });

    test(
      'generateCommitMessage creates its preview file with mktemp, not a '
      'fixed name',
      () async {
        exec.next = const SSHCommandResult(
          exitCode: 0,
          stdout: 'generated message\n',
          stderr: '',
        );
        final msg = await git.generateCommitMessage('/repo');
        final call = exec.calls.single;
        expect(call[0], 'sh');
        expect(call[1], '-c');
        final script = call[2];
        expect(
          script,
          contains('mktemp'),
          reason:
              'a fixed preview filename would let another local user (or a '
              'racing second call) pre-plant a symlink at that path before '
              'the hook writes to it',
        );
        expect(script, isNot(contains(': > "\$tmp"')));
        expect(msg, 'generated message');
      },
    );

    test('stashPop targets the indexed stash', () async {
      await git.stashPop('/repo', 2);
      expect(exec.calls.single, ['git', 'stash', 'pop', 'stash@{2}']);
    });

    test('stashPush --include-untracked', () async {
      await git.stashPush('/repo', includeUntracked: true, message: 'wip');
      expect(exec.calls.single, [
        'git',
        'stash',
        'push',
        '--include-untracked',
        '-m',
        'wip',
      ]);
    });

    test('stashClear drops every stash', () async {
      await git.stashClear('/repo');
      expect(exec.calls.single, ['git', 'stash', 'clear']);
    });

    test('stashShow requests the stash patch', () async {
      await git.stashShow('/repo', 3);
      expect(exec.calls.single, [
        'git',
        'stash',
        'show',
        '-p',
        '--no-color',
        'stash@{3}',
      ]);
    });

    test('resolveConflict --ours then stages', () async {
      await git.resolveConflict('/repo', 'a.dart', useOurs: true);
      expect(exec.calls[0], ['git', 'checkout', '--ours', '--', 'a.dart']);
      expect(exec.calls[1], ['git', 'add', '--', 'a.dart']);
    });

    test('resolveConflict --theirs then stages', () async {
      await git.resolveConflict('/repo', 'a.dart', useOurs: false);
      expect(exec.calls[0], ['git', 'checkout', '--theirs', '--', 'a.dart']);
      expect(exec.calls[1], ['git', 'add', '--', 'a.dart']);
    });

    test(
      'resolveConflictMany resolves every path with 2 invocations total',
      () async {
        await git.resolveConflictMany(
          '/repo',
          ['a.dart', 'b.dart'],
          useOurs: true,
        );
        expect(exec.calls[0], [
          'git',
          'checkout',
          '--ours',
          '--',
          'a.dart',
          'b.dart',
        ]);
        expect(exec.calls[1], ['git', 'add', '--', 'a.dart', 'b.dart']);
        expect(exec.calls, hasLength(2));
      },
    );

    test('mergeAbort', () async {
      await git.mergeAbort('/repo');
      expect(exec.calls.single, ['git', 'merge', '--abort']);
    });

    test('throws GitException on non-zero exit', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'nothing to commit',
      );
      expect(
        () => git.commit('/repo', message: 'x'),
        throwsA(isA<GitException>()),
      );
    });

    test('stashList parses index, branch, message and relative date', () async {
      const us = GitService.fieldSep;
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout:
            'stash@{0}${us}WIP on main: abc1234 tweak${us}2 hours ago\n'
            'stash@{1}${us}On feature: manual note${us}3 days ago\n',
        stderr: '',
      );
      final stashes = await git.stashList('/repo');
      expect(stashes, hasLength(2));
      expect(stashes[0].index, 0);
      expect(stashes[0].branch, 'main');
      expect(stashes[0].message, contains('tweak'));
      expect(stashes[0].relativeDate, '2 hours ago');
      // subject strips the "WIP on <branch>: <sha> " boilerplate.
      expect(stashes[0].subject, 'tweak');
      expect(stashes[1].index, 1);
      expect(stashes[1].branch, 'feature');
      expect(stashes[1].relativeDate, '3 days ago');
      expect(stashes[1].subject, 'manual note');
    });

    test('stashList tolerates the legacy 2-field format (no date)', () async {
      const us = GitService.fieldSep;
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'stash@{0}${us}WIP on main: abc1234 tweak\n',
        stderr: '',
      );
      final stashes = await git.stashList('/repo');
      expect(stashes.single.relativeDate, '');
      expect(stashes.single.subject, 'tweak');
    });

    test('stash subject strips a full 64-hex SHA-256 short id', () async {
      const us = GitService.fieldSep;
      // A SHA-256 repo abbreviates to up to 64 hex; a {7,40} bound would stop
      // mid-hash and leak the tail into the subject.
      const sha256 =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'stash@{0}${us}WIP on main: $sha256 tweak${us}2 hours ago\n',
        stderr: '',
      );
      final stashes = await git.stashList('/repo');
      expect(stashes.single.subject, 'tweak');
    });

    test('validateRepoPath checks rev-parse', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'true\n',
        stderr: '',
      );
      await git.validateRepoPath('/repo');
      expect(exec.calls.single, ['git', 'rev-parse', '--is-inside-work-tree']);
    });

    test('validateRepoPath throws when not a work tree', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'false\n',
        stderr: '',
      );
      await expectLater(
        git.validateRepoPath('/not-a-repo'),
        throwsA(isA<GitException>()),
      );
    });
  });

  group('GlabService mutations build correct argv', () {
    late _FakeExecutor exec;
    late GlabService glab;

    setUp(() {
      exec = _FakeExecutor();
      glab = GlabService(exec);
    });

    test('approveMergeRequest posts to the approve endpoint', () async {
      await glab.approveMergeRequest('/repo', 5);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/merge_requests/5/approve',
        '--method',
        'POST',
        '-i',
      ]);
    });

    test('retryPipeline posts to the retry endpoint', () async {
      await glab.retryPipeline('/repo', 9);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/pipelines/9/retry',
        '--method',
        'POST',
        '-i',
      ]);
    });

    test(
      'catalog-style lists (issues/releases) paginate; the bounded activity '
      'feeds (pipelines/jobs) do not',
      () async {
        await glab.issues('/repo');
        expect(exec.calls[0], contains('--paginate'));
        await glab.releases('/repo');
        expect(exec.calls[1], contains('--paginate'));

        await glab.pipelines('/repo');
        expect(exec.calls[2], isNot(contains('--paginate')));
        await glab.jobs('/repo', 1);
        expect(exec.calls[3], isNot(contains('--paginate')));
      },
    );

    test('createMergeRequest uses subcommand argv (not -f fields)', () async {
      await glab.createMergeRequest(
        '/repo',
        sourceBranch: 'feat',
        targetBranch: 'main',
        title: 'Add feat',
      );
      expect(exec.calls.single, [
        'glab',
        'mr',
        'create',
        '--source-branch',
        'feat',
        '--target-branch',
        'main',
        '--title',
        'Add feat',
      ]);
    });

    test(
      'createMergeRequest passes special characters as discrete args',
      () async {
        await glab.createMergeRequest(
          '/repo',
          sourceBranch: 'feat',
          targetBranch: 'main',
          title: 'fix: a=b',
          description: 'line1\nline2',
        );
        expect(exec.calls.single, [
          'glab',
          'mr',
          'create',
          '--source-branch',
          'feat',
          '--target-branch',
          'main',
          '--title',
          'fix: a=b',
          '--description',
          'line1\nline2',
        ]);
      },
    );

    test('createMergeRequest maps the enriched authoring fields to flags', () async {
      await glab.createMergeRequest(
        '/repo',
        sourceBranch: 'feat',
        targetBranch: 'main',
        title: 'Add feat',
        draft: true,
        reviewers: ['alice', 'bob'],
        assignees: ['carol'],
        labels: ['backend', 'urgent'],
        milestone: 'v2',
        squash: true,
        removeSourceBranch: true,
      );
      expect(exec.calls.single, [
        'glab',
        'mr',
        'create',
        '--source-branch',
        'feat',
        '--target-branch',
        'main',
        '--title',
        'Add feat',
        '--draft',
        '--reviewer',
        'alice,bob',
        '--assignee',
        'carol',
        '--label',
        'backend,urgent',
        '--milestone',
        'v2',
        '--squash-before-merge',
        '--remove-source-branch',
      ]);
    });

    test('checkoutMergeRequest runs glab mr checkout <iid>', () async {
      await glab.checkoutMergeRequest('/repo', 42);
      expect(exec.calls.single, ['glab', 'mr', 'checkout', '42']);
    });

    test('mergeMergeRequest PUTs to the merge endpoint', () async {
      await glab.mergeMergeRequest('/repo', 12);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/merge_requests/12/merge',
        '--method',
        'PUT',
        '-i',
      ]);
    });

    test(
      'read endpoints pass an explicit --method GET (never implicit POST)',
      () async {
        // A `-f` field with no explicit method makes glab POST — which 400s a
        // read endpoint. pipelines() must force GET.
        await glab.pipelines('/repo', perPage: 20);
        expect(exec.calls.single, [
          'glab',
          'api',
          'projects/:id/pipelines',
          '--method',
          'GET',
          '-f',
          'per_page=20',
          '-i',
        ]);
      },
    );

    test('data calls never inject a token into the environment', () async {
      // The token lives in the remote glab credential store, never in a
      // per-command env prelude (which would leak via /proc/<pid>/cmdline).
      await glab.mergeRequests('/repo');
      expect(exec.envs.single, isNull);
    });

    test('api treats HTTP 401 as failure even when exit code is 0', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'HTTP/2 401\n\n{"message":"401 Unauthorized"}',
        stderr: '',
      );
      await expectLater(glab.pipelines('/repo'), throwsA(isA<GlabException>()));
    });

    test('loginWithToken pipes the token via stdin, never argv', () async {
      exec.results.addAll(const [
        SSHCommandResult(
          exitCode: 0,
          stdout: 'git@gitlab.example.com:grp/repo.git',
          stderr: '',
        ),
        SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      ]);
      await glab.loginWithToken('/repo', 'glpat-secret');

      expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[1], [
        'glab',
        'auth',
        'login',
        '--hostname',
        'gitlab.example.com',
        '--stdin',
      ]);
      // Token goes to stdin of the login call, and appears in no argument vector.
      expect(exec.stdins[1], 'glpat-secret');
      expect(exec.stdins[0], isNull);
      expect(
        exec.calls.expand((c) => c).any((a) => a.contains('glpat-secret')),
        isFalse,
      );
    });

    test(
      'loginWithToken resolves the host from https and ssh:// remotes',
      () async {
        exec.results.addAll(const [
          SSHCommandResult(
            exitCode: 0,
            stdout: 'https://gitlab.example.com/grp/repo.git',
            stderr: '',
          ),
          SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
        ]);
        await glab.loginWithToken('/repo', 't');
        expect(exec.calls[1][4], 'gitlab.example.com');

        exec.calls.clear();
        exec.results.addAll(const [
          SSHCommandResult(
            exitCode: 0,
            stdout: 'ssh://git@gitlab.example.com:2222/grp/repo.git',
            stderr: '',
          ),
          SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
        ]);
        await glab.loginWithToken('/repo', 't');
        expect(exec.calls[1][4], 'gitlab.example.com');
      },
    );

    test(
      'loginWithToken throws when the origin host cannot be resolved',
      () async {
        exec.results.add(
          const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
        );
        expect(
          () => glab.loginWithToken('/repo', 't'),
          throwsA(isA<GlabException>()),
        );
      },
    );

    test(
      'loginWithToken rejects a blank token before touching the remote — '
      '`glab auth login --stdin` does not reject one itself and would hang '
      'in an interactive OAuth device-flow instead',
      () async {
        await expectLater(
          glab.loginWithToken('/repo', '   '),
          throwsA(isA<GlabException>()),
        );
        expect(exec.calls, isEmpty, reason: 'no remote call was ever made');
      },
    );

    test('graphql requests -i and cross-checks the HTTP status', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'
            '{"data": {"project": {"issues": {"nodes": []}}}}',
        stderr: '',
      );
      await glab.graphql('/repo', 'query { x }');
      expect(exec.calls.single, contains('-i'));
    });

    test(
      'graphql throws on a real HTTP failure even when glab\'s own exit code '
      'is misleadingly 0 (glab #911) — instead of masking it as empty data',
      () async {
        exec.next = const SSHCommandResult(
          exitCode: 0,
          stdout: 'HTTP/2 401\r\ncontent-type: application/json\r\n\r\n'
              '{"message": "401 Unauthorized"}',
          stderr: '',
        );
        await expectLater(
          glab.graphql('/repo', 'query { x }'),
          throwsA(isA<GlabException>()),
        );
      },
    );
  });
}
