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

  // --------------------------------------------------------------------
  // MADR 0031 Phase 4 — creating under a chosen namespace.
  // --------------------------------------------------------------------
  //
  // The open question the MADR names: GitLab identifies groups by `full_path`,
  // so a **nested** subgroup (`team/sub/name`, two levels) should work, but
  // glab's own help example is single-level. Nothing but a live create settles
  // it.
  //
  // The namespaces are read from `MAGIC_GIT_LIVE_NAMESPACES` (comma-separated
  // group full paths) and are never hardcoded: a group path is an internal
  // identifier, and internal identifiers do not go into committed content.
  // Run it as, for example:
  //
  //   MAGIC_GIT_LIVE_NAMESPACES=team,team/subgroup \
  //     flutter test --run-skipped -t live-forge \
  //     test/create_repo_wire_live_test.dart
  //
  // What it proves, beyond "a project appeared": that the project landed at
  // the path we asked for, and that origin resolves to *that* path rather than
  // to `<login>/<name>`. Those two can disagree — passing `--group` instead of
  // the positional path is exactly how — and the disagreement is silent.
  group('GitLab live create under a namespace', () {
    final namespaces = (Platform.environment['MAGIC_GIT_LIVE_NAMESPACES'] ?? '')
        .split(',')
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toList();

    for (final namespace in namespaces) {
      final depth = namespace.split('/').length;
      test(
        'creates in $namespace (${depth == 1 ? 'top-level' : 'nested, '
                  '$depth levels'}) and resolves origin there',
        () async {
          if (!await _cliReady('glab')) {
            markTestSkipped('glab not installed/authenticated');
            return;
          }
          final host = await _glabHost() ?? 'gitlab.com';
          final name =
              'magicgit-nstest-${DateTime.now().millisecondsSinceEpoch}';
          final fullPath = '$namespace/$name';
          final dest = await initLocalRepo(name);
          final glab = GlabService(executor);
          var created = false;

          try {
            // The sheet passes the composed path POSITIONALLY. Never --group:
            // that creates the project correctly and then leaves
            // resolveOriginUrl looking up `<login>/<name>`.
            final createResult = await glab.createRepoInExisting(
              repoPath: dest,
              name: fullPath,
              private: true,
              host: host,
            );
            created = true;

            // 1. It landed where we asked. Asked of the API, not inferred from
            //    the create output — the output is what a --group create would
            //    also print.
            final encoded = fullPath
                .split('/')
                .map(Uri.encodeComponent)
                .join('%2F');
            final project = await executor.execute(
              repoPath: dest,
              gitArgs: ['glab', 'api', 'projects/$encoded'],
              extraEnv: GlabService.hostEnv(host),
              retries: 0,
            );
            expect(
              project.isSuccess,
              isTrue,
              reason: 'the project must exist at $fullPath: ${project.stderr}',
            );
            final decoded = jsonDecode(project.stdout) as Map<String, dynamic>;
            expect(
              decoded['path_with_namespace'],
              fullPath,
              reason: 'created somewhere other than the requested namespace',
            );

            // 2. Origin resolves to THAT project, not to `<login>/<name>`.
            final resolved = await glab.resolveOriginUrl(
              repoPath: dest,
              name: fullPath,
              host: host,
              createOutput: createResult.stdout,
            );
            final url = resolved.url;
            expect(
              url,
              isNotNull,
              reason:
                  'origin must resolve after a namespaced create '
                  '(${resolved.detail})',
            );
            expect(
              url,
              contains(fullPath),
              reason:
                  'origin points at a different path than was created — '
                  'this is the --group trap (${resolved.detail})',
            );

            // 3. And it is a real, pushable remote.
            final add = await executor.execute(
              repoPath: dest,
              gitArgs: ['git', 'remote', 'add', 'origin', url!],
              retries: 0,
            );
            expect(add.isSuccess, isTrue, reason: 'remote add: ${add.stderr}');
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
              reason: 'the pushed branch must exist under $fullPath',
            );
          } finally {
            // Always delete, even when an expect above failed.
            if (created) {
              final encoded = fullPath
                  .split('/')
                  .map(Uri.encodeComponent)
                  .join('%2F');
              final del = await executor.execute(
                repoPath: dest,
                gitArgs: ['glab', 'api', 'projects/$encoded', '-X', 'DELETE'],
                extraEnv: GlabService.hostEnv(host),
                retries: 0,
              );
              if (!del.isSuccess) {
                // Loud, not fatal: a leaked project must never be silent.
                // ignore: avoid_print
                print('WARNING: could not delete $fullPath: ${del.stderr}');
              }
            }
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    }
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
