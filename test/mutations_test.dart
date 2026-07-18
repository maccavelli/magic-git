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
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) async {
    calls.add(gitArgs);
    envs.add(extraEnv);
    stdins.add(stdin);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

/// Pins the undo-capture wrapper every undoable mutation runs through: one
/// `sh -c` script that brackets the shell-escaped [mutation] with
/// sentinel-delimited pre/post state prints and preserves its exit code (see
/// `GitService._runCaptured`). Returns the script for further, op-specific
/// pinning (extra capture fields).
String expectCapturedScript(List<String> call, String mutation) {
  expect(call, hasLength(3));
  expect(call.sublist(0, 2), ['sh', '-c']);
  final script = call[2];
  expect(
    script,
    startsWith(
      r'pre=$(git rev-parse -q --verify HEAD); '
      r'preref=$(git symbolic-ref -q --short HEAD); ',
    ),
  );
  expect(script, contains('; $mutation; rc=\$?; '));
  expect(script, endsWith(r'exit $rc'));
  return script;
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
      expect(
        exec.calls.single,
        ['git', 'add', '--', ':(literal)lib/main.dart'],
      );
    });

    test('unstage uses restore --staged', () async {
      await git.unstage('/repo', 'lib/main.dart');
      expect(exec.calls.single, [
        'git',
        'restore',
        '--staged',
        '--',
        ':(literal)lib/main.dart',
      ]);
    });

    test('commit passes --no-gpg-sign and the message as one arg', () async {
      await git.commit('/repo', message: 'fix: a thing');
      expectCapturedScript(
        exec.calls.single,
        "'git' 'commit' '--no-gpg-sign' '-m' 'fix: a thing'",
      );
    });

    test('commit with no message omits -m (lets the hook write it)', () async {
      await git.commit('/repo');
      expectCapturedScript(exec.calls.single, "'git' 'commit' '--no-gpg-sign'");
      exec.calls.clear();
      await git.commit('/repo', message: '   ');
      expectCapturedScript(exec.calls.single, "'git' 'commit' '--no-gpg-sign'");
    });

    test('checkout', () async {
      await git.checkout('/repo', 'feature');
      expectCapturedScript(
        exec.calls.single,
        "'git' 'checkout' '--end-of-options' 'feature'",
      );
    });

    test('createBranch checks out by default', () async {
      await git.createBranch('/repo', 'feat');
      // No --end-of-options before the name: -b consumes its next token
      // verbatim, so the guard itself would become the branch name (a real
      // bug this pin used to enshrine — caught by the real-git undo tests).
      expectCapturedScript(
        exec.calls.single,
        "'git' 'checkout' '-b' 'feat'",
      );
    });

    test('createBranch without checkout uses git branch', () async {
      await git.createBranch('/repo', 'feat', checkout: false);
      expectCapturedScript(
        exec.calls.single,
        "'git' 'branch' '--end-of-options' 'feat'",
      );
    });

    test('deleteBranch force uses -D and captures the doomed tip', () async {
      await git.deleteBranch('/repo', 'old', force: true);
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'branch' '-D' '--end-of-options' 'old'",
      );
      // The tip OID is captured before the delete so undo can recreate it.
      expect(
        script,
        contains(r"x0=$(git rev-parse -q --verify 'refs/heads/old'); "),
      );
    });

    test('renameBranch moves the ref with --end-of-options', () async {
      await git.renameBranch('/repo', 'old-name', 'new-name');
      expect(exec.calls.single, [
        'git',
        'branch',
        '-m',
        '--end-of-options',
        'old-name',
        'new-name',
      ]);
    });

    test('rebaseContinue silences the editor; rebaseAbort is bare', () async {
      await git.rebaseContinue('/repo');
      await git.rebaseAbort('/repo');
      // core.editor=true: --continue opens an editor for the folded message
      // without it, and a remote host has no editor to open.
      expect(exec.calls[0], [
        'git',
        '-c',
        'core.editor=true',
        'rebase',
        '--continue',
      ]);
      expect(exec.calls[1], ['git', 'rebase', '--abort']);
    });

    test('setUpstream uses the = form; unsetUpstream guards the positional',
        () async {
      await git.setUpstream('/repo', 'feature', 'origin/feature');
      await git.unsetUpstream('/repo', 'feature');
      expect(exec.calls[0], [
        'git',
        'branch',
        '--set-upstream-to=origin/feature',
        '--end-of-options',
        'feature',
      ]);
      expect(exec.calls[1], [
        'git',
        'branch',
        '--unset-upstream',
        '--end-of-options',
        'feature',
      ]);
    });

    test('deleteRemoteBranch pushes a delete to the named remote', () async {
      await git.deleteRemoteBranch('/repo', 'origin', 'feature');
      expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[1], [
        'git',
        'push',
        '--delete',
        '--end-of-options',
        'origin',
        'feature',
      ]);
    });

    test('discard restores the working tree path', () async {
      await git.discard('/repo', 'a.dart');
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'restore' '--' ':(literal)a.dart'",
      );
      // A flavor-A snapshot (stash create, anchored on a hidden ref) is taken
      // in the same invocation, before the restore destroys the content.
      expect(script, contains(r'git stash create 2>/dev/null'));
      expect(script, contains("git update-ref 'refs/magic-git/snapshots/"));
      expect(script, contains('GIT_AUTHOR_NAME=magic-git'));
      expect(script, contains("git for-each-ref 'refs/magic-git/snapshots'"),
          reason: 'expiry pruning piggybacks on every snapshot');
    });

    test('discardHunk reverse-applies from stdin with a flavor-A snapshot',
        () async {
      await git.discardHunk('/repo', 'PATCH-TEXT', path: 'a.dart');
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'apply' '-R' '--recount' '--whitespace=nowarn' '-'",
      );
      // Snapshotted before the reverse-apply destroys the hunk — the same
      // ⌘Z net every other worktree discard has.
      expect(script, contains(r'git stash create 2>/dev/null'));
      expect(exec.stdins.single, 'PATCH-TEXT',
          reason: 'the patch travels on stdin, never argv');
    });

    test('unstageAll uses a bare reset — the one form that also works on an '
        'unborn HEAD', () async {
      await git.unstageAll('/repo');
      expect(exec.calls.single, ['git', 'reset', '-q']);
    });

    test('deleteFile removes any path via rm -f, guarded by --', () async {
      // Unlike removeUntrackedFile (git clean, which refuses tracked files),
      // this is the file-tree pane's generic delete and must work on tracked
      // files too — hence a plain rm.
      await git.deleteFile('/repo', 'lib/main.dart');
      final script = expectCapturedScript(
        exec.calls.single,
        "'rm' '-f' '--' 'lib/main.dart'",
      );
      // rm destroys content stash create can't see (untracked/ignored), so
      // the snapshot is flavor B: a temp-index plumbing commit of the doomed
      // paths.
      expect(script, contains('GIT_INDEX_FILE="\$idx" git add -f -- '
          "':(literal)lib/main.dart' 2>/dev/null"));
      expect(script, contains(r'git write-tree'));
      expect(script, contains(r'git commit-tree "$t" ${pre:+-p "$pre"}'));
      expect(script, contains("git update-ref 'refs/magic-git/snapshots/"));
    });

    test('deleteFile keeps a leading-dash path out of rm option parsing',
        () async {
      await git.deleteFile('/repo', '-weird.txt');
      expectCapturedScript(
        exec.calls.single,
        "'rm' '-f' '--' '-weird.txt'",
      );
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

    test('readFileBase64 pipes the file through base64, stripping newlines '
        'remote-side', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'aGVsbG8=',
        stderr: '',
      );
      final b64 = await git.readFileBase64('/repo', 'assets/logo.png');
      // The `tr -d '\r\n'` strips base64's wrapping newlines on the remote, so
      // the caller can decode directly without a client-side whitespace copy.
      // The `test -r` guard runs first: a pipeline reports its LAST command's
      // exit status, so without it a missing/unreadable file would exit 0
      // with empty output instead of failing.
      final call = exec.calls.single;
      expect(call[0], 'sh');
      expect(call[1], '-c');
      final script = call[2];
      expect(script, startsWith("test -r 'assets/logo.png' || "));
      expect(script, contains('exit 66'));
      expect(script, endsWith("base64 < 'assets/logo.png' | tr -d '\\r\\n'"));
      expect(b64, 'aGVsbG8=');
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
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'restore' '--staged' '--worktree' '--source=HEAD' '--' ':(literal)a.dart'",
      );
      expect(script, contains(r'git stash create 2>/dev/null'),
          reason: 'flavor-A snapshot taken before the destroy');
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
      // A .gitignore without a trailing newline must be normalized before the
      // append, or the new pattern concatenates onto the last existing line
      // (`*.logbuild/`), corrupting both rules.
      expect(script, contains('tail -c 1'));
    });

    test('stageMany/unstageMany/discardMany/removeUntrackedFilesMany/'
        'discardStagedMany/addToGitignoreMany cover the whole list in one '
        'invocation', () async {
      final paths = ['a.dart', 'b.dart'];

      await git.stageMany('/repo', paths);
      expect(exec.calls.single, [
        'git',
        'add',
        '--',
        ':(literal)a.dart',
        ':(literal)b.dart',
      ]);
      exec.calls.clear();

      await git.unstageMany('/repo', paths);
      expect(exec.calls.single, [
        'git',
        'restore',
        '--staged',
        '--',
        ':(literal)a.dart',
        ':(literal)b.dart',
      ]);
      exec.calls.clear();

      await git.discardMany('/repo', paths);
      expectCapturedScript(
        exec.calls.single,
        "'git' 'restore' '--' ':(literal)a.dart' ':(literal)b.dart'",
      );
      exec.calls.clear();

      await git.removeUntrackedFilesMany('/repo', paths);
      final cleanScript = expectCapturedScript(
        exec.calls.single,
        "'git' 'clean' '-f' '--' ':(literal)a.dart' ':(literal)b.dart'",
      );
      expect(
        cleanScript,
        contains(
          "git add -f -- ':(literal)a.dart' ':(literal)b.dart' 2>/dev/null",
        ),
        reason: 'flavor-B snapshot covers every doomed path',
      );
      exec.calls.clear();

      await git.discardStagedMany('/repo', paths);
      expectCapturedScript(
        exec.calls.single,
        "'git' 'restore' '--staged' '--worktree' '--source=HEAD' '--' "
        "':(literal)a.dart' ':(literal)b.dart'",
      );
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
        ':(literal)a.dart',
      ]);
    });

    test('diffFile with defaults omits -w and -U', () async {
      await git.diffFile('/repo', path: 'a.dart', staged: false);
      expect(
        exec.calls.single,
        ['git', 'diff', '--no-color', '--', ':(literal)a.dart'],
      );
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

    // A remote-less pull/push first resolves the current branch's upstream
    // remote (auth must follow the remote git will actually contact); an
    // empty answer falls back to origin.
    const upstreamProbe = [
      'sh',
      '-c',
      r'git config --get "branch.$(git symbolic-ref --short -q HEAD).remote"',
    ];

    test('fetch / pull / push', () async {
      await git.fetch('/repo');
      await git.pull('/repo');
      await git.push('/repo');
      // fetch --all may touch either forge: both CLI helpers, no remote probe.
      expect(exec.calls[0], [
        'git',
        '-c',
        'credential.helper=',
        '-c',
        'credential.helper=!gh auth git-credential',
        '-c',
        'credential.helper=!glab auth git-credential',
        'fetch',
        '--all',
        '--prune',
      ]);
      // pull/push resolve the tracked remote, then probe it; empty URL → no
      // forge auth args.
      expect(exec.calls[1], upstreamProbe);
      expect(exec.calls[2], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[3], ['git', 'pull', '--ff-only']);
      expect(exec.calls[4], upstreamProbe);
      expect(exec.calls[5], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[6], ['git', 'push']);
    });

    test('a resolved environment pins fetch/push auth to the absolute CLI '
        'path (no PATH re-resolution of a shadowing shim)', () async {
      // The connect-time probe resolved gh/glab to these absolute paths.
      exec.configureEnvironment(
        binaries: const {
          'gh': '/home/u/.local/bin/gh',
          'glab': '/home/u/.local/bin/glab',
        },
      );

      await git.fetch('/repo');
      expect(exec.calls[0], [
        'git',
        '-c',
        'credential.helper=',
        '-c',
        'credential.helper=!/home/u/.local/bin/gh auth git-credential',
        '-c',
        'credential.helper=!/home/u/.local/bin/glab auth git-credential',
        'fetch',
        '--all',
        '--prune',
      ]);

      exec.results.addAll(const [
        SSHCommandResult(exitCode: 1, stdout: '', stderr: ''), // upstream probe
        SSHCommandResult(
          exitCode: 0,
          stdout: 'https://gitlab.example.com/me/r.git\n',
          stderr: '',
        ),
      ]);
      await git.push('/repo');
      expect(exec.calls[3], [
        'git',
        '-c',
        'credential.helper=',
        '-c',
        'credential.helper=!/home/u/.local/bin/glab auth git-credential',
        'push',
      ]);
    });

    test('pull mode maps to the right flag', () async {
      await git.pull('/repo', mode: PullMode.rebase);
      await git.pull('/repo', mode: PullMode.merge);
      await git.pull('/repo', remote: 'origin', branch: 'main');
      // Each remote-less pull resolves the upstream remote, then probes it;
      // an explicit remote skips the resolve.
      expect(exec.calls[0], upstreamProbe);
      expect(exec.calls[1], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[2], ['git', 'pull', '--rebase']);
      expect(exec.calls[3], upstreamProbe);
      expect(exec.calls[4], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[5], ['git', 'pull', '--no-rebase']);
      expect(exec.calls[6], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[7], [
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
      expect(exec.calls[0], upstreamProbe);
      expect(exec.calls[1], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[2], ['git', 'pull', '--ff-only']);
    });

    test('push injects gh credential helper for https github remotes', () async {
      exec.results.addAll(const [
        // Upstream probe: no upstream configured → falls back to origin.
        SSHCommandResult(exitCode: 1, stdout: '', stderr: ''),
        SSHCommandResult(
          exitCode: 0,
          stdout: 'https://github.com/me/r.git\n',
          stderr: '',
        ),
      ]);
      await git.push('/repo');
      expect(exec.calls[0], upstreamProbe);
      expect(exec.calls[1], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[2], [
        'git',
        '-c',
        'credential.helper=',
        '-c',
        'credential.helper=!gh auth git-credential',
        'push',
      ]);
    });

    test('a branch tracking a non-origin remote routes auth through THAT '
        'remote', () async {
      exec.results.addAll(const [
        // Upstream probe: the branch tracks `upstream`, not origin.
        SSHCommandResult(exitCode: 0, stdout: 'upstream\n', stderr: ''),
        SSHCommandResult(
          exitCode: 0,
          stdout: 'https://github.com/them/r.git\n',
          stderr: '',
        ),
      ]);
      await git.push('/repo');
      expect(exec.calls[0], upstreamProbe);
      expect(exec.calls[1], ['git', 'remote', 'get-url', 'upstream'],
          reason: 'the auth probe must follow the tracked remote');
      expect(exec.calls[2], [
        'git',
        '-c',
        'credential.helper=',
        '-c',
        'credential.helper=!gh auth git-credential',
        'push',
      ]);
    });

    test('push force / upstream / tags flags', () async {
      await git.push('/repo', force: PushForce.withLease);
      await git.push('/repo', force: PushForce.force);
      await git.push('/repo', setUpstream: true, followTags: true);
      await git.push('/repo', remote: 'origin', branch: 'feat');
      // Resolve + probe + push triples (empty origin → no auth -c flags);
      // the explicit-remote push skips the resolve.
      expect(exec.calls[0], upstreamProbe);
      expect(exec.calls[1], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[2], ['git', 'push', '--force-with-lease']);
      expect(exec.calls[3], upstreamProbe);
      expect(exec.calls[4], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[5], ['git', 'push', '--force']);
      expect(exec.calls[6], upstreamProbe);
      expect(exec.calls[7], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[8], ['git', 'push', '-u', '--follow-tags']);
      expect(exec.calls[9], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[10], [
        'git',
        'push',
        '--end-of-options',
        'origin',
        'feat',
      ]);
    });

    test('createTag: lightweight vs annotated', () async {
      await git.createTag('/repo', 'v1.0.0');
      var script = expectCapturedScript(
        exec.calls.single,
        "'git' 'tag' '--end-of-options' 'v1.0.0' 'HEAD'",
      );
      // The created ref's OID is a POST-mutation capture — an annotated
      // tag's object doesn't exist beforehand — and becomes the undo guard.
      expect(
        script,
        contains(r"y0=$(git rev-parse -q --verify 'refs/tags/v1.0.0'); "),
      );
      expect(
        script.indexOf(r'rc=$?'),
        lessThan(script.indexOf('y0=')),
        reason: 'the created-tag OID must be captured after the mutation',
      );
      exec.calls.clear();
      await git.createTag('/repo', 'v1.0.0', message: 'release', ref: 'abc123');
      script = expectCapturedScript(
        exec.calls.single,
        "'git' 'tag' '-a' '-m' 'release' '--end-of-options' 'v1.0.0' 'abc123'",
      );
      expect(
        script,
        contains(r"y0=$(git rev-parse -q --verify 'refs/tags/v1.0.0'); "),
      );
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
      expectCapturedScript(
        exec.calls.single,
        "'git' '-c' 'user.name=Jane Dev' '-c' 'user.email=jane@example.com' "
        "'tag' '-a' '-m' 'release' '--end-of-options' 'v1.0.0' 'HEAD'",
      );
    });

    test('deleteTag / pushTag', () async {
      await git.deleteTag('/repo', 'v1.0.0');
      await git.pushTag('/repo', 'v1.0.0');
      final script = expectCapturedScript(
        exec.calls[0],
        "'git' 'tag' '-d' '--end-of-options' 'v1.0.0'",
      );
      // The tag *object* OID (not peeled) is captured so undo restores an
      // annotated tag byte-identical via update-ref.
      expect(
        script,
        contains(r"x0=$(git rev-parse -q --verify 'refs/tags/v1.0.0'); "),
      );
      expect(exec.calls[1], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[2], [
        'git',
        'push',
        '--end-of-options',
        'origin',
        'refs/tags/v1.0.0',
      ]);
    });

    test('pushTags sends explicit refspecs in one invocation', () async {
      await git.pushTags('/repo', ['v1.0.0', 'v1.1.0']);
      // Explicit refspecs, deliberately not --tags: a diverged tag would
      // poison a --tags batch with its rejection; a list can't.
      expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[1], [
        'git',
        'push',
        '--end-of-options',
        'origin',
        'refs/tags/v1.0.0',
        'refs/tags/v1.1.0',
      ]);
    });

    test('revParse guards the rev positional with --end-of-options', () async {
      await git.revParse('/repo', 'HEAD');
      expect(exec.calls[0], [
        'git',
        'rev-parse',
        '--verify',
        '--quiet',
        '--end-of-options',
        'HEAD',
      ]);
    });

    test('pushTags rejects an empty list — the argv would degenerate to a '
        'default branch push', () async {
      await expectLater(
        () => git.pushTags('/repo', []),
        throwsArgumentError,
      );
      expect(exec.calls, isEmpty, reason: 'nothing may reach the remote');
    });

    test('deleteRemoteTag uses the full refname', () async {
      await git.deleteRemoteTag('/repo', 'origin', 'v1.0.0');
      // refs/tags/ disambiguates from a branch of the same name.
      expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[1], [
        'git',
        'push',
        '--delete',
        '--end-of-options',
        'origin',
        'refs/tags/v1.0.0',
      ]);
    });

    test('lsRemoteTags: argv, unpeeled oids, graceful failure', () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout:
            'aaaa000000000000000000000000000000000000\trefs/tags/v1.0.0\n'
            // The peel line: an annotated tag's underlying commit. Skipped —
            // the tag *object* oid (the line above) is what GitRef.oid holds
            // locally, and ref-level inequality is what predicts a push
            // rejection.
            'bbbb000000000000000000000000000000000000\trefs/tags/v1.0.0^{}\n'
            'cccc000000000000000000000000000000000000\trefs/tags/v2.0.0\n'
            // Non-tag and malformed lines are ignored.
            'dddd000000000000000000000000000000000000\trefs/heads/main\n'
            'garbage-without-a-tab\n',
        stderr: '',
      );
      final tags = await git.lsRemoteTags('/repo');
      // Probe first (non-URL stdout → no forge helper); then ls-remote.
      expect(exec.calls[0], ['git', 'remote', 'get-url', 'origin']);
      expect(exec.calls[1], [
        'git',
        'ls-remote',
        '--tags',
        '--end-of-options',
        'origin',
      ]);
      expect(tags, {
        'v1.0.0': 'aaaa000000000000000000000000000000000000',
        'v2.0.0': 'cccc000000000000000000000000000000000000',
      });

      // Unreachable remote → null ("unknown"), never a throw.
      exec.calls.clear();
      exec.next = const SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: could not read from remote repository',
      );
      expect(await git.lsRemoteTags('/repo'), isNull);
    });

    test('cherryPick: plain vs merge mainline, and abort', () async {
      await git.cherryPick('/repo', 'abc');
      expectCapturedScript(
        exec.calls.single,
        "'git' 'cherry-pick' '--end-of-options' 'abc'",
      );
      exec.calls.clear();
      await git.cherryPick('/repo', 'abc', mainline: 1);
      expectCapturedScript(
        exec.calls.single,
        "'git' 'cherry-pick' '-m' '1' '--end-of-options' 'abc'",
      );
      exec.calls.clear();
      await git.cherryPickAbort('/repo');
      expect(exec.calls.single, ['git', 'cherry-pick', '--abort']);
    });

    test('revert: no-edit, merge mainline, and abort', () async {
      await git.revert('/repo', 'abc');
      expectCapturedScript(
        exec.calls.single,
        "'git' 'revert' '--no-edit' '--end-of-options' 'abc'",
      );
      exec.calls.clear();
      await git.revert('/repo', 'abc', mainline: 2);
      expectCapturedScript(
        exec.calls.single,
        "'git' 'revert' '--no-edit' '-m' '2' '--end-of-options' 'abc'",
      );
      exec.calls.clear();
      await git.revertAbort('/repo');
      expect(exec.calls.single, ['git', 'revert', '--abort']);
    });

    test('reset maps each mode', () async {
      await git.reset('/repo', 'abc', mode: ResetMode.soft);
      await git.reset('/repo', 'abc', mode: ResetMode.mixed);
      await git.reset('/repo', 'abc', mode: ResetMode.hard);
      expectCapturedScript(
        exec.calls[0],
        "'git' 'reset' '--soft' '--end-of-options' 'abc'",
      );
      // Mixed additionally snapshots the pre-reset index as a tree so undo
      // can restore exactly what was staged.
      final mixed = expectCapturedScript(
        exec.calls[1],
        "'git' 'reset' '--mixed' '--end-of-options' 'abc'",
      );
      expect(mixed, contains(r'x0=$(git write-tree 2>/dev/null); '));
      // Hard destroys uncommitted content, so it takes a flavor-A snapshot.
      final hard = expectCapturedScript(
        exec.calls[2],
        "'git' 'reset' '--hard' '--end-of-options' 'abc'",
      );
      expect(hard, contains(r'git stash create 2>/dev/null'));
    });

    test('branchFrom roots the branch at a start point', () async {
      await git.branchFrom('/repo', 'feat', 'abc');
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'checkout' '-b' 'feat' '--end-of-options' 'abc'",
      );
      // The start point is resolved pre-mutation so undo knows the created
      // tip even when the creation doesn't move HEAD.
      expect(script, contains(r"x0=$(git rev-parse -q --verify 'abc^{commit}')"));
      exec.calls.clear();
      await git.branchFrom('/repo', 'feat', 'abc', checkout: false);
      expectCapturedScript(
        exec.calls.single,
        "'git' 'branch' '--end-of-options' 'feat' 'abc'",
      );
    });

    test('amendCommit: keep message vs rewrite', () async {
      await git.amendCommit('/repo');
      expectCapturedScript(
        exec.calls.single,
        "'git' 'commit' '--amend' '--no-gpg-sign' '--no-edit'",
      );
      exec.calls.clear();
      await git.amendCommit('/repo', message: 'new subject');
      expectCapturedScript(
        exec.calls.single,
        "'git' 'commit' '--amend' '--no-gpg-sign' '-m' 'new subject'",
      );
    });

    test('pendingOp detects an in-progress operation from the git dir', () async {
      // pendingOp is bundled with status/refs into one combined `sh -c`
      // round trip (see GitService._fetchSnapshot) — the operation name is
      // the last of the sep-delimited sections (sep matches
      // GitService._snapshotSep: STX-wrapped "RMGSNAP").
      const sep = 'RMGSNAP';
      String combined(String op) =>
          '$sep' '0$sep' '$sep' '0$sep' '$sep' '0$sep' '$op\n';
      exec.results.add(
        SSHCommandResult(exitCode: 0, stdout: combined('cherry-pick'), stderr: ''),
      );
      expect(await git.pendingOp('/repo'), PendingOp.cherryPick);

      exec.results.add(
        SSHCommandResult(exitCode: 0, stdout: combined('none'), stderr: ''),
      );
      expect(await git.pendingOp('/repo'), PendingOp.none);
    });

    test('remotes parses the configured-remote section of the snapshot — the '
        'config-level truth an empty repo needs (its remote-tracking refs '
        'are necessarily absent)', () async {
      const sep = '\u0002RMGSNAP\u0002';
      exec.results.add(
        const SSHCommandResult(
          exitCode: 0,
          stdout:
              '${sep}0$sep${sep}0${sep}origin\nupstream\n${sep}0${sep}none\n',
          stderr: '',
        ),
      );
      expect(await git.remotes('/repo'), ['origin', 'upstream']);
    });

    test('merge builds the right argv per mode', () async {
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      await git.merge('/repo', 'feature', mode: MergeMode.noFf);
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'merge' '--no-edit' '--no-ff' '--end-of-options' 'feature'",
      );
      expect(script, contains(r'git stash create 2>/dev/null'),
          reason: "undo is reset --hard back — snapshot the merge's "
              'uncommitted survivors first');
      exec.calls.clear();
      exec.results.add(
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      // Squash doesn't move HEAD, so undo validation would be meaningless —
      // it stays a plain argv with no capture wrapper.
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
      // One --grep per word, ANDed: a two-word search means "mentions both",
      // not "contains this exact phrase" (which is all a joined pattern can
      // ever match, and why typing two words used to find nothing).
      expect(args, containsAll(['--grep=fix', '--grep=bug', '--all-match']));
      expect(args, contains('--author=jane'));
      // Case-insensitive whenever there is a pattern at all — not only when a
      // message term happens to be present alongside the author.
      expect(args, contains('--regexp-ignore-case'));
      expect(args, contains('--extended-regexp'));
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
      expect(a2, containsAllInOrder(['--', ':(literal)lib/x.dart']));
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
      expectCapturedScript(
        exec.calls.single,
        "'git' '-c' 'user.name=Jane Dev' '-c' 'user.email=jane@example.com' "
        "'commit' '--no-gpg-sign' '-m' 'hi'",
      );
    });

    test('stashPush with and without a message', () async {
      await git.stashPush('/repo');
      expect(exec.calls.single, ['git', 'stash', 'push']);
      exec.calls.clear();
      await git.stashPush('/repo', message: 'wip');
      expect(exec.calls.single, ['git', 'stash', 'push', '-m', 'wip']);
    });

    test('stashPush path-scopes with :(literal) pathspecs after --', () async {
      // The paths are exact files the UI showed — a bare pathspec would glob
      // (`a[1].txt` also matches `a1.txt`), so each is wrapped in :(literal).
      await git.stashPush(
        '/repo',
        includeUntracked: true,
        paths: ['a[1].txt', 'lib/b.dart'],
      );
      expect(exec.calls.single, [
        'git',
        'stash',
        'push',
        '--include-untracked',
        '--',
        ':(literal)a[1].txt',
        ':(literal)lib/b.dart',
      ]);
    });

    test('stashDrop drops behind the stale-OID guard, capturing the subject '
        'first', () async {
      await git.stashDrop('/repo', 1, expectedOid: 'dddddddddddddddddddddddddddddddddddddddd');
      final call = exec.calls.single;
      expect(call.sublist(0, 2), ['sh', '-c']);
      final script = call[2];
      // The guard: stash@{1} must still BE the stash the UI rendered, or the
      // subshell exits 42 and nothing is touched.
      expect(
        script,
        contains('( [ "\$(git rev-parse -q --verify ' "'stash@{1}')\" = "
            "'dddddddddddddddddddddddddddddddddddddddd' ] || exit 42; git stash drop 'stash@{1}' )"),
      );
      // Subject captured pre-drop so undo can `stash store` it back.
      expect(
        script,
        contains(r"x0=$(git log -1 --format=%s 'stash@{1}' 2>/dev/null); "),
      );
    });

    test('a stale drop surfaces StashStaleException, not a raw git error',
        () async {
      exec.next = const SSHCommandResult(exitCode: 42, stdout: '', stderr: '');
      await expectLater(
        git.stashDrop('/repo', 1, expectedOid: 'dddddddddddddddddddddddddddddddddddddddd'),
        throwsA(isA<StashStaleException>()),
      );
    });

    test('stashApply adds --index only when asked', () async {
      await git.stashApply('/repo', 'e' * 40);
      expect(exec.calls.single,
          ['git', 'stash', 'apply', '--end-of-options', 'e' * 40]);
      exec.calls.clear();
      await git.stashApply('/repo', 'e' * 40, restoreIndex: true);
      expect(exec.calls.single,
          ['git', 'stash', 'apply', '--index', '--end-of-options', 'e' * 40]);
    });

    test('stashPop --index runs `pop --index` inside the stale guard',
        () async {
      await git.stashPop('/repo', 0, expectedOid: 'e' * 40, restoreIndex: true);
      expect(exec.calls.single[2],
          contains("git stash pop --index 'stash@{0}' )"));
    });

    test('stashBranch runs `stash branch <name> <sel>` behind the stale guard, '
        'capturing subject + snapshot', () async {
      await git.stashBranch('/repo', 'feature-x', index: 2, expectedOid: 'e' * 40);
      final script = exec.calls.single[2];
      expect(
        script,
        contains('( [ "\$(git rev-parse -q --verify ' "'stash@{2}')\" = "
            "'${'e' * 40}' ] || exit 42; git stash branch 'feature-x' 'stash@{2}' )"),
      );
      // Subject captured pre-op for undo's `stash store` message.
      expect(script,
          contains(r"x0=$(git log -1 --format=%s 'stash@{2}' 2>/dev/null); "));
    });

    test('a stale stashBranch surfaces StashStaleException', () async {
      exec.next = const SSHCommandResult(exitCode: 42, stdout: '', stderr: '');
      await expectLater(
        git.stashBranch('/repo', 'x', index: 0, expectedOid: 'e' * 40),
        throwsA(isA<StashStaleException>()),
      );
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
        ':(literal)lib/a.dart',
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

    test('stashPop runs behind the same stale-OID guard and journals the '
        'popped stash', () async {
      await git.stashPop('/repo', 2, expectedOid: 'dddddddddddddddddddddddddddddddddddddddd');
      final call = exec.calls.single;
      expect(call.sublist(0, 2), ['sh', '-c']);
      expect(
        call[2],
        contains("|| exit 42; git stash pop 'stash@{2}' )"),
      );
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

    test('stashClear drops every stash, capturing them all first', () async {
      await git.stashClear('/repo');
      final script = expectCapturedScript(
        exec.calls.single,
        "'git' 'stash' 'clear'",
      );
      expect(
        script,
        contains("x0=\$(git log -g --format='%H %gs' refs/stash 2>/dev/null)"),
        reason: 'every stash OID+subject is captured so undo can re-store '
            'them in order',
      );
    });

    test('stashShow requests the patch by OID, untracked included', () async {
      await git.stashShow('/repo', 'dddddddddddddddddddddddddddddddddddddddd');
      expect(exec.calls.single, [
        'git',
        'stash',
        'show',
        '-p',
        '--include-untracked',
        '--no-color',
        '--end-of-options',
        'dddddddddddddddddddddddddddddddddddddddd',
      ]);
    });

    test('stashApply addresses the stash by OID', () async {
      await git.stashApply('/repo', 'dddddddddddddddddddddddddddddddddddddddd');
      expect(exec.calls.single, [
        'git',
        'stash',
        'apply',
        '--end-of-options',
        'dddddddddddddddddddddddddddddddddddddddd',
      ]);
    });

    test('resolveConflict --ours then stages', () async {
      await git.resolveConflict('/repo', 'a.dart', useOurs: true);
      expect(exec.calls[0], [
        'git',
        'checkout',
        '--ours',
        '--',
        ':(literal)a.dart',
      ]);
      expect(exec.calls[1], ['git', 'add', '--', ':(literal)a.dart']);
    });

    test('resolveConflict --theirs then stages', () async {
      await git.resolveConflict('/repo', 'a.dart', useOurs: false);
      expect(exec.calls[0], [
        'git',
        'checkout',
        '--theirs',
        '--',
        ':(literal)a.dart',
      ]);
      expect(exec.calls[1], ['git', 'add', '--', ':(literal)a.dart']);
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
          ':(literal)a.dart',
          ':(literal)b.dart',
        ]);
        expect(exec.calls[1], [
          'git',
          'add',
          '--',
          ':(literal)a.dart',
          ':(literal)b.dart',
        ]);
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
      // Field order is %gd, %H, %cr, %gs — the free-text message goes last.
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout:
            'stash@{0}${us}aaa111${us}2 hours ago'
            '${us}WIP on main: abc1234 tweak\n'
            'stash@{1}${us}bbb222${us}3 days ago'
            '${us}On feature: manual note\n',
        stderr: '',
      );
      final stashes = await git.stashList('/repo');
      expect(stashes, hasLength(2));
      expect(stashes[0].index, 0);
      expect(stashes[0].oid, 'aaa111');
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

    test('stashList tolerates an empty trailing message field', () async {
      const us = GitService.fieldSep;
      // With the message last, %gs can be empty (a bare `git stash` with no
      // subject leaves a trailing separator + empty field) — the date column,
      // now a fixed middle field, still parses.
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'stash@{0}${us}ccc333${us}2 hours ago$us\n',
        stderr: '',
      );
      final stashes = await git.stashList('/repo');
      expect(stashes.single.oid, 'ccc333');
      expect(stashes.single.relativeDate, '2 hours ago');
      expect(stashes.single.message, '');
    });

    test('stashList skips a row truncated before the message field', () async {
      const us = GitService.fieldSep;
      // A transport hiccup that clips the row to three fields (no message
      // separator at all) is dropped rather than mis-parsed.
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'stash@{0}${us}ccc333${us}2 hours ago\n',
        stderr: '',
      );
      expect(await git.stashList('/repo'), isEmpty);
    });

    test('stash subject strips a full 64-hex SHA-256 short id', () async {
      const us = GitService.fieldSep;
      // A SHA-256 repo abbreviates to up to 64 hex; a {7,40} bound would stop
      // mid-hash and leak the tail into the subject.
      const sha256 =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout:
            'stash@{0}${us}ddd444${us}2 hours ago'
            '${us}WIP on main: $sha256 tweak\n',
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
      'api(paginate: true) paginates; the bounded activity feeds '
      '(pipelines/jobs) do not',
      () async {
        await glab.api('/repo', 'projects/:id/issues', paginate: true);
        expect(exec.calls[0], contains('--paginate'));

        await glab.pipelines('/repo');
        expect(exec.calls[1], isNot(contains('--paginate')));
        await glab.jobs('/repo', 1);
        expect(exec.calls[2], isNot(contains('--paginate')));
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

    test('mergeMergeRequest with squash sends the typed squash field', () async {
      await glab.mergeMergeRequest('/repo', 12, squash: true);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/merge_requests/12/merge',
        '--method',
        'PUT',
        '-f',
        'squash=true',
        '-i',
      ]);
    });

    test('mergeMergeRequest sends should_remove_source_branch when asked',
        () async {
      await glab.mergeMergeRequest('/repo', 12, removeSourceBranch: true);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/merge_requests/12/merge',
        '--method',
        'PUT',
        '-f',
        'should_remove_source_branch=true',
        '-i',
      ]);
    });

    test('closeMergeRequest / reopenMergeRequest PUT a state_event', () async {
      await glab.closeMergeRequest('/repo', 12);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/merge_requests/12',
        '--method',
        'PUT',
        '-f',
        'state_event=close',
        '-i',
      ]);
      exec.calls.clear();
      await glab.reopenMergeRequest('/repo', 12);
      expect(exec.calls.single, [
        'glab',
        'api',
        'projects/:id/merge_requests/12',
        '--method',
        'PUT',
        '-f',
        'state_event=reopen',
        '-i',
      ]);
    });

    test('setMergeRequestDraft toggles --draft / --ready via the subcommand',
        () async {
      await glab.setMergeRequestDraft('/repo', 12, draft: true);
      expect(exec.calls.single, ['glab', 'mr', 'update', '12', '--draft']);
      exec.calls.clear();
      await glab.setMergeRequestDraft('/repo', 12, draft: false);
      expect(exec.calls.single, ['glab', 'mr', 'update', '12', '--ready']);
    });

    test('commentOnMergeRequest notes the body as a discrete token', () async {
      await glab.commentOnMergeRequest('/repo', 12, 'looks good = ship it');
      expect(exec.calls.single, [
        'glab',
        'mr',
        'note',
        '12',
        '--message',
        'looks good = ship it',
      ]);
    });

    test('editMergeRequest sends only the provided fields', () async {
      await glab.editMergeRequest('/repo', 12, title: 'New title');
      expect(exec.calls.single, [
        'glab',
        'mr',
        'update',
        '12',
        '--title',
        'New title',
      ]);
    });

    test('closeIssue / reopenIssue', () async {
      await glab.closeIssue('/repo', 8);
      expect(exec.calls.single, ['glab', 'issue', 'close', '8']);
      exec.calls.clear();
      await glab.reopenIssue('/repo', 8);
      expect(exec.calls.single, ['glab', 'issue', 'reopen', '8']);
    });

    test('commentOnIssue notes the body as a discrete token', () async {
      await glab.commentOnIssue('/repo', 8, 'thanks for the report');
      expect(exec.calls.single, [
        'glab',
        'issue',
        'note',
        '8',
        '--message',
        'thanks for the report',
      ]);
    });

    test('editIssue updates only the provided fields', () async {
      await glab.editIssue('/repo', 8, title: 'Retitled');
      expect(exec.calls.single, [
        'glab',
        'issue',
        'update',
        '8',
        '--title',
        'Retitled',
      ]);
    });

    test('mergeRequestFields fetches title + description for the edit form',
        () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: '{"title":"A title","description":"A body"}',
        stderr: '',
      );
      final fields = await glab.mergeRequestFields('/repo', 12);
      expect(exec.calls.single, [
        'glab',
        'mr',
        'view',
        '12',
        '--output',
        'json',
      ]);
      expect(fields.title, 'A title');
      expect(fields.description, 'A body');
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
