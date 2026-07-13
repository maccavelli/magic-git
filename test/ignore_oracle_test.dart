// GitIgnoreOracle: which watched paths git actually cares about, answered from
// memory almost always. The point of it is cost — a build drops thousands of
// files into an ignored directory, and none of them may reach the app as a
// "the repo changed" tick, nor cost a round trip to dismiss.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/ignore_oracle.dart';

/// A git that ignores anything under `build/` or `.dart_tool/`, and counts how
/// often it is asked — the number that decides whether this is viable over SSH.
class _FakeGit extends GitService {
  _FakeGit() : super(LocalCommandExecutor());

  int calls = 0;
  final List<List<String>> asked = [];
  bool fail = false;

  @override
  Future<Set<String>> checkIgnore(String repoPath, List<String> paths) async {
    calls++;
    asked.add(paths);
    if (fail) throw StateError('git exploded');
    return {
      for (final p in paths)
        if (p == 'build' ||
            p.startsWith('build/') ||
            p == '.dart_tool' ||
            p.startsWith('.dart_tool/') ||
            p.endsWith('.log'))
          p,
    };
  }
}

void main() {
  const repo = '/repo';

  test('an ignored directory answers for its whole subtree, forever', () async {
    final git = _FakeGit();
    final oracle = GitIgnoreOracle(git);

    expect(await oracle.visible(repo, {'build/a0.o'}), isEmpty);
    expect(git.calls, 1, reason: 'the first artifact must ask git');

    // Everything a build subsequently drops in there — at any depth, with names
    // git has never seen — is now answered from an ancestor's verdict. This is
    // the whole reason the watcher can stay ignorant of a running build: git
    // guarantees a file under an excluded directory cannot be re-included, so
    // the directory's verdict is final.
    for (var i = 1; i < 500; i++) {
      expect(await oracle.visible(repo, {'build/a$i.o'}), isEmpty);
    }
    expect(
      await oracle.visible(repo, {'build/macos/Debug/deep/nested/thing.dylib'}),
      isEmpty,
    );
    expect(git.calls, 1, reason: '500 more artifacts must cost nothing');
  });

  test('paths git does care about survive', () async {
    final git = _FakeGit();
    final oracle = GitIgnoreOracle(git);

    expect(
      await oracle.visible(repo, {'lib/a.dart', 'build/x.o', 'app.log'}),
      {'lib/a.dart'},
    );
    // A second look at the same file is free too.
    final before = git.calls;
    expect(await oracle.visible(repo, {'lib/a.dart'}), {'lib/a.dart'});
    expect(git.calls, before);
  });

  test('one burst is one round trip, whatever its size', () async {
    final git = _FakeGit();
    final oracle = GitIgnoreOracle(git);

    final burst = {
      for (var i = 0; i < 50; i++) 'build/o$i.o',
      for (var i = 0; i < 50; i++) 'lib/f$i.dart',
    };
    expect(await oracle.visible(repo, burst), hasLength(50));
    expect(git.calls, 1, reason: 'batched over stdin, not one call per path');
  });

  test("git's own state is never dismissed as ignored", () async {
    final git = _FakeGit();
    final oracle = GitIgnoreOracle(git);

    // `.git/index`, HEAD and refs are what a commit, a stage, or a checkout
    // moves — the most meaningful events there are. check-ignore has no opinion
    // on them and must never be consulted.
    expect(
      await oracle.visible(repo, {'.git/index', '.git/HEAD', '.git/refs/heads/main'}),
      {'.git/index', '.git/HEAD', '.git/refs/heads/main'},
    );
    expect(git.calls, 0);
  });

  test('an edited .gitignore voids the verdicts drawn from it', () async {
    final git = _FakeGit();
    final oracle = GitIgnoreOracle(git);

    expect(await oracle.visible(repo, {'build/a.o'}), isEmpty);
    expect(git.calls, 1);

    // The rules themselves changed — every decision made under the old ones is
    // now worthless, and must be made again rather than trusted.
    expect(GitIgnoreOracle.isIgnoreSource('.gitignore'), isTrue);
    expect(GitIgnoreOracle.isIgnoreSource('sub/dir/.gitignore'), isTrue);
    expect(GitIgnoreOracle.isIgnoreSource('.git/info/exclude'), isTrue);
    expect(GitIgnoreOracle.isIgnoreSource('lib/a.dart'), isFalse);

    oracle.forgetRepo(repo);
    expect(await oracle.visible(repo, {'build/a.o'}), isEmpty);
    expect(git.calls, 2, reason: 'the verdict must be re-derived, not reused');
  });

  test('a git that fails is not a licence to ignore real edits', () async {
    final git = _FakeGit()..fail = true;
    final oracle = GitIgnoreOracle(git);

    // Failing *closed* would mean a broken git silently freezes every diff pane
    // in the app. The caller is expected to fail open — treat the burst as real
    // — so the cost of not knowing is a wasted refresh, never a stale view.
    await expectLater(
      oracle.visible(repo, {'lib/a.dart'}),
      throwsA(isA<StateError>()),
    );
  });
}
