// LIVE end-to-end reproduction of the create-repo wizard's remote wiring,
// against the REAL gh/glab CLIs and the REAL LocalCommandExecutor — the exact
// sequence _CreateRepositorySheetState._submit runs, with the exact env.
//
// The unit tests all mock the executor, so they can only pin what argv we
// SEND — every live failure so far has been in what the CLIs actually DO.
// This suite exists to close that gap. It is tagged and skipped unless the
// CLIs are present and authenticated.
//
// GitLab: FULL cycle — create a uniquely-named private project on the
// signed-in instance, wire origin, push, verify, then DELETE the project.
// GitHub: non-mutating half only (cloneUrl resolution + protocol probe
// against an existing repo) — the signed-in token has no delete_repo scope,
// so a created repo could not be cleaned up.
@Tags(['integration', 'live-forge'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';

Future<bool> _cliReady(String cli) async {
  try {
    final r = await Process.run(cli, ['auth', 'status']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// The glab-authenticated host (first host in `glab auth status` output), or
/// null when signed out.
Future<String?> _glabHost() async {
  try {
    final r = await Process.run('glab', ['auth', 'status']);
    final all = '${r.stdout}\n${r.stderr}';
    for (final line in const LineSplitter().convert(all)) {
      final t = line.trim();
      if (t.isNotEmpty &&
          !t.startsWith('✓') &&
          !t.startsWith('-') &&
          !t.startsWith('[') &&
          !t.contains(' ')) {
        return t;
      }
    }
  } catch (_) {}
  return null;
}

Future<String?> _ghHost() async {
  try {
    final r = await Process.run('gh', ['auth', 'status']);
    final all = '${r.stdout}\n${r.stderr}';
    for (final line in const LineSplitter().convert(all)) {
      final t = line.trim();
      if (t.isNotEmpty &&
          !t.startsWith('✓') &&
          !t.startsWith('-') &&
          !t.startsWith('[') &&
          !t.contains(' ')) {
        return t;
      }
    }
  } catch (_) {}
  return null;
}

void main() {
  late Directory tempDir;
  late LocalCommandExecutor executor;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('create_wire_live_');
    executor = LocalCommandExecutor();
    // The app always probes before This-Mac work (localEnvironmentProvider
    // .ensure()) — replicate that so argv rewriting and the augmented PATH
    // behave exactly as in the GUI app, not as in this terminal.
    final env = await EnvironmentResolver(executor).resolve(tempDir.path);
    executor.configureEnvironment(path: env.path, binaries: env.found);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// The sheet's local steps: init -b main, README, add, commit.
  Future<String> initLocalRepo(String name) async {
    final init = await executor.execute(
      repoPath: tempDir.path,
      gitArgs: ['git', 'init', '-b', 'main', '--', name],
      retries: 0,
    );
    expect(init.isSuccess, isTrue, reason: 'git init: ${init.stderr}');
    final dest = '${tempDir.path}/$name';
    await executor.uploadBytes(
      '$dest/README.md',
      Uint8List.fromList(utf8.encode('# $name\n')),
    );
    const authorName = 'Magic Git Live Test';
    const authorEmail = 'livetest@magic-git.invalid';
    for (final argv in [
      ['git', 'config', '--local', 'user.name', authorName],
      ['git', 'config', '--local', 'user.email', authorEmail],
      ['git', 'add', '--', 'README.md'],
      [
        'git',
        '-c',
        'user.name=$authorName',
        '-c',
        'user.email=$authorEmail',
        'commit',
        '--no-gpg-sign',
        '-m',
        'Initial commit',
      ],
    ]) {
      final r = await executor.execute(
        repoPath: dest,
        gitArgs: argv,
        retries: 0,
      );
      expect(r.isSuccess, isTrue, reason: '${argv.join(' ')}: ${r.stderr}');
    }
    return dest;
  }

  group('GitLab live create wire', () {
    test('create → cloneUrl → remote add → push → verify → delete', () async {
      if (!await _cliReady('glab')) {
        markTestSkipped('glab not installed/authenticated');
        return;
      }
      final host = await _glabHost() ?? 'gitlab.com';
      final name = 'magicgit-livetest-${DateTime.now().millisecondsSinceEpoch}';
      final dest = await initLocalRepo(name);
      final glab = GlabService(executor);
      String? projectPathForCleanup;

      try {
        // --- the sheet's exact forge steps -------------------------------
        final created = await glab.createRepoInExisting(
          repoPath: dest,
          name: name,
          private: true,
          host: host,
        );

        final resolved = await glab.resolveOriginUrl(
          repoPath: dest,
          name: name,
          host: host,
          createOutput: created.stdout,
        );
        final url = resolved.url;
        expect(
          url,
          isNotNull,
          reason:
              'origin URL must resolve right after create '
              '(${resolved.detail})',
        );
        expect(url, contains(name));

        // Track the namespace/name for cleanup regardless of later failures.
        final m = RegExp('([^/:]+)/$name').firstMatch(url!);
        projectPathForCleanup = m == null ? name : '${m.group(1)}/$name';

        final add = await executor.execute(
          repoPath: dest,
          gitArgs: ['git', 'remote', 'add', 'origin', url],
          retries: 0,
        );
        expect(add.isSuccess, isTrue, reason: 'remote add: ${add.stderr}');

        // Same argv the create-repo sheet uses: forge CLI credential helper
        // for this one command so ambient host helpers can't feed a wrong
        // password over HTTPS.
        final push = await executor.execute(
          repoPath: dest,
          gitArgs: [
            'git',
            ...forgeGitAuthConfigArgs(Forge.gitlab),
            'push',
            '-u',
            'origin',
            'main',
          ],
          timeout: const Duration(minutes: 2),
          retries: 0,
        );
        expect(
          push.isSuccess,
          isTrue,
          reason: 'push: ${push.stderr}\n${push.stdout}',
        );

        // --- the sheet's verification ------------------------------------
        final verify = await executor.execute(
          repoPath: dest,
          gitArgs: ['git', 'remote', 'get-url', 'origin'],
          retries: 0,
        );
        expect(verify.isSuccess, isTrue);
        expect(verify.stdout.trim(), url);

        final lsRemote = await executor.execute(
          repoPath: dest,
          gitArgs: [
            'git',
            ...forgeGitAuthConfigArgs(Forge.gitlab),
            'ls-remote',
            '--heads',
            'origin',
          ],
          timeout: const Duration(minutes: 2),
          retries: 0,
        );
        expect(lsRemote.isSuccess, isTrue);
        expect(
          lsRemote.stdout,
          contains('refs/heads/main'),
          reason: 'the pushed branch must exist on the forge',
        );

        // --- name-collision recovery (the classic partial-success path) --
        // A re-run against a name that already exists on the forge: create
        // throws, and the sheet must still be able to wire origin from the
        // lookup chain alone (no create output).
        await expectLater(
          glab.createRepoInExisting(
            repoPath: dest,
            name: name,
            private: true,
            host: host,
          ),
          throwsA(isA<GlabException>()),
          reason: 'the project already exists — create must fail loudly',
        );
        final recovered = await glab.resolveOriginUrl(
          repoPath: dest,
          name: name,
          host: host,
        );
        expect(
          recovered.url,
          url,
          reason:
              'lookup-only resolution must recover the same URL '
              '(${recovered.detail})',
        );
      } finally {
        // Always delete the live project, even when an expect above failed.
        if (projectPathForCleanup != null) {
          final encoded = projectPathForCleanup
              .split('/')
              .map(Uri.encodeComponent)
              .join('%2F');
          final del = await executor.execute(
            repoPath: dest,
            gitArgs: ['glab', 'api', 'projects/$encoded', '-X', 'DELETE'],
            extraEnv: GlabService.hostEnv(host),
            retries: 0,
          );
          // Surface (not fail) cleanup problems so a leaked project is loud.
          if (!del.isSuccess) {
            // ignore: avoid_print
            print(
              'WARNING: could not delete $projectPathForCleanup: '
              '${del.stderr}',
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('GitHub live wire (non-mutating half)', () {
    test(
      'cloneUrl resolves an existing bare-name repo; protocol probe works',
      () async {
        if (!await _cliReady('gh')) {
          markTestSkipped('gh not installed/authenticated');
          return;
        }
        final host = await _ghHost() ?? 'github.com';
        final gh = GhService(executor);

        // The user's newest repo stands in for a just-created one — resolving
        // it by BARE name is exactly what cloneUrl does after create.
        final list = await executor.execute(
          repoPath: tempDir.path,
          gitArgs: [
            'gh',
            'repo',
            'list',
            '--json',
            'name',
            '--limit',
            '1',
            '--jq',
            '.[0].name',
          ],
          extraEnv: GhService.hostEnv(host),
          retries: 0,
        );
        final name = list.stdout.trim();
        if (!list.isSuccess || name.isEmpty) {
          markTestSkipped('no repos on the account to resolve');
          return;
        }

        final resolved = await gh.resolveOriginUrl(
          repoPath: tempDir.path,
          name: name,
          host: host,
        );
        expect(
          resolved.url,
          isNotNull,
          reason: 'bare-name resolution must work (${resolved.detail})',
        );
        expect(resolved.url, contains(name));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    // The create-repo regression: gh is authenticated, but plain `git` over
    // HTTPS does not use that store — and a host-wide credential helper that
    // answers for every host (e.g. a glab-only wrapper) feeds GitHub a wrong
    // password. The sheet's push must clear ambient helpers and use
    // `gh auth git-credential` for the one command.
    test(
      'https git auth via gh credential helper reaches an existing repo',
      () async {
        if (!await _cliReady('gh')) {
          markTestSkipped('gh not installed/authenticated');
          return;
        }
        final host = await _ghHost() ?? 'github.com';
        final list = await executor.execute(
          repoPath: tempDir.path,
          gitArgs: [
            'gh',
            'repo',
            'list',
            '--json',
            'nameWithOwner,url',
            '--limit',
            '1',
          ],
          extraEnv: GhService.hostEnv(host),
          retries: 0,
        );
        if (!list.isSuccess || list.stdout.trim().isEmpty) {
          markTestSkipped('no repos on the account to probe');
          return;
        }
        final decoded = jsonDecode(list.stdout.trim());
        if (decoded is! List || decoded.isEmpty) {
          markTestSkipped('gh repo list returned no entries');
          return;
        }
        final first = decoded.first;
        if (first is! Map) {
          markTestSkipped('unexpected gh repo list shape');
          return;
        }
        final https = first['url'];
        if (https is! String || https.isEmpty) {
          markTestSkipped('no https url on listed repo');
          return;
        }
        final url = https.endsWith('.git') ? https : '$https.git';

        // Init a throwaway repo so `git` has a cwd; origin is the live HTTPS URL.
        final dest = await initLocalRepo('gh-auth-probe');
        final add = await executor.execute(
          repoPath: dest,
          gitArgs: ['git', 'remote', 'add', 'origin', url],
          retries: 0,
        );
        expect(add.isSuccess, isTrue, reason: add.stderr);

        // Without the forge helper, ambient helpers (or none) often fail here
        // under GIT_TERMINAL_PROMPT=0 — the app always sets that.
        final ls = await executor.execute(
          repoPath: dest,
          gitArgs: [
            'git',
            ...forgeGitAuthConfigArgs(Forge.github),
            'ls-remote',
            '--heads',
            'origin',
          ],
          timeout: const Duration(minutes: 2),
          retries: 0,
        );
        expect(
          ls.isSuccess,
          isTrue,
          reason:
              'HTTPS ls-remote via gh auth git-credential must work '
              '(${ls.stderr}\n${ls.stdout})',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
