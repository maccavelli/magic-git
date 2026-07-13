// The whole refresh pipeline, end to end, against a real repository with the
// real filesystem watcher running: watcher → ignore filter → per-path edit
// stamps → the cached diff a pane is showing.
//
// Written against real git and a real watcher deliberately. Every bug this
// covers lived in the seams — a filesystem event that git would never have
// reported, a status refresh standing in for "some file's bytes changed", an
// invalidation landing on a fetch that had not returned yet. Fakes agree with
// whatever the code believes; only the real pipeline can disagree with it.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LocalConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(backend: ConnectionBackend.local);
}

/// A worktree diff that takes a beat — which is all a real repo behind a
/// congested read lane, or an SSH round trip, actually is. The bug this file
/// exists for only appears when a change can arrive *during* a fetch.
class _SlowGit extends GitService {
  _SlowGit() : super(LocalCommandExecutor());

  int diffFetches = 0;
  int statusFetches = 0;

  @override
  Future<GitStatus> status(String repoPath) {
    statusFetches++;
    return super.status(repoPath);
  }

  @override
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    diffFetches++;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    return super.diffFile(
      repoPath,
      path: path,
      staged: staged,
      ignoreWhitespace: ignoreWhitespace,
      context: context,
    );
  }
}

void main() {
  test('a build churning ignored files costs nothing, and the diff still shows',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    final repo = Directory.systemTemp.createTempSync('worktree_inval_');
    addTearDown(() => repo.deleteSync(recursive: true));

    Future<void> sh(List<String> argv) async {
      final result = await Process.run(
        argv.first,
        argv.skip(1).toList(),
        workingDirectory: repo.path,
      );
      if (result.exitCode != 0) {
        throw StateError('${argv.join(' ')}\n${result.stderr}');
      }
    }

    await sh(['git', 'init', '-b', 'main']);
    File('${repo.path}/.gitignore').writeAsStringSync('build/\n');
    File('${repo.path}/tracked.txt').writeAsStringSync('one\ntwo\nthree\n');
    File('${repo.path}/other.txt').writeAsStringSync('other\n');
    await sh(['git', 'add', '.']);
    await sh([
      'git',
      '-c', 'user.name=T',
      '-c', 'user.email=t@e',
      'commit',
      '-m', 'initial',
    ]);
    // The file the user is about to open a diff on.
    File('${repo.path}/tracked.txt').writeAsStringSync('one\nCHANGED\nthree\n');
    Directory('${repo.path}/build').createSync();

    final git = _SlowGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        connectionProvider.overrideWith(_LocalConnection.new),
      ],
    );
    addTearDown(container.dispose);

    // The repo pane's watch-tick handler, as it really is.
    var ticks = 0;
    final tickSub = container.listen(repoWatchProvider(repo.path), (_, next) {
      final event = next.value;
      if (event == null) return;
      ticks++;
      if (event.mode == WatchMode.eventDriven) {
        final edits = container.read(worktreeEditsProvider.notifier);
        if (event.isScoped) {
          edits.noteFiles(repo.path, event.paths);
        } else {
          edits.noteRepo(repo.path);
        }
      }
      container.invalidate(statusProvider(repo.path));
    });
    addTearDown(tickSub.close);

    final statusSub = container.listen(statusProvider(repo.path), (_, _) {});
    addTearDown(statusSub.close);
    await container.read(statusProvider(repo.path).future);
    // Let the watcher arm and emit its start-up resync tick.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final diffKey = (repo.path, 'tracked.txt', false, false, 3);

    // ---------------------------------------------------------------- churn
    // A build writing artifacts git ignores, continuously, while the user opens
    // a diff. This is what used to spin forever: every artifact was a "the repo
    // changed" tick, which restarted the in-flight read, which never landed.
    var building = true;
    unawaited(() async {
      var i = 0;
      while (building) {
        File('${repo.path}/build/artifact_${i++}.o').writeAsStringSync('$i');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }());
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final ticksAtOpen = ticks;
    final statusAtOpen = git.statusFetches;

    // The user clicks the file. `when` is what the pane renders.
    final rendered = <String>[];
    final diffSub = container.listen(
      fileDiffProvider(diffKey),
      (_, next) => rendered.add(
        next.when(
          loading: () => 'spinner',
          error: (_, _) => 'error',
          data: (_) => 'diff',
        ),
      ),
      fireImmediately: true,
    );
    addTearDown(diffSub.close);

    await Future<void>.delayed(const Duration(seconds: 6));
    building = false;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      rendered,
      ['spinner', 'diff'],
      reason: 'the diff must load once and then stay: the pane spun forever '
          'when ignored churn kept restarting the read that had not landed',
    );
    expect(
      ticks - ticksAtOpen,
      0,
      reason: 'a burst git can see nothing in must not reach the app at all',
    );
    expect(
      git.statusFetches - statusAtOpen,
      0,
      reason: 'nor cost a `git status` — over SSH that is a round trip a second',
    );
    expect(git.diffFetches, 1);

    // ------------------------------------------------- an unrelated real edit
    // A tracked file changes — a genuine repo change, which must refresh status.
    // It must NOT refetch the diff of a different file.
    final diffsBefore = git.diffFetches;
    File('${repo.path}/other.txt').writeAsStringSync('other CHANGED\n');
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(
      ticks,
      greaterThan(ticksAtOpen),
      reason: 'a real edit must still reach the app',
    );
    expect(
      git.diffFetches,
      diffsBefore,
      reason: "another file's edit must not refetch this file's diff — the "
          'invalidation is per path, not per repo',
    );

    // ------------------------------------------------------- editing the file
    // The case porcelain cannot see: the record stays `M tracked.txt`, the bytes
    // change. It must refresh, and show the new bytes.
    File('${repo.path}/tracked.txt').writeAsStringSync('one\nAGAIN\nthree\n');
    await Future<void>.delayed(const Duration(seconds: 4));

    expect(
      git.diffFetches,
      greaterThan(diffsBefore),
      reason: 'a content-only edit to the open file must refresh its diff',
    );
    expect(
      container.read(fileDiffProvider(diffKey)).value,
      contains('AGAIN'),
      reason: 'and the pane must be showing the new content',
    );
  }, timeout: const Timeout(Duration(seconds: 180)));
}
