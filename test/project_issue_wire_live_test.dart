// LIVE verification of the Project tab's issue/milestone wiring against the
// REAL gh/glab CLIs — the behaviors the unit tests can only argv-pin:
//
//   * `glab issue create --title` WITHOUT `--description` must not drop into
//     an interactive editor over a PTY-less exec channel.
//   * `glab issue list --output json` / `glab issue view <iid> --output json`
//     shapes (`iid`, bare-string `labels`, `description`).
//   * `glab api projects/:id/milestones` REST shape (global `id`, `due_date`,
//     `description`) through [ForgeMilestone.fromGlabRest].
//   * `gh issue list --json` / `gh issue view --json body` shapes and the
//     hand page-walked `gh api …/milestones`.
//
// GitLab: FULL cycle — create a uniquely-named private project, create issues
// in it (one with an empty description), list/view them, create + list a
// milestone, then DELETE the project (issues and milestones go with it).
// GitHub: non-mutating half only (list/detail against an existing repo) —
// issues cannot be deleted via the API, so a created one could not be
// cleaned up.
@Tags(['integration', 'live-forge'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
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
    tempDir = Directory.systemTemp.createTempSync('issue_wire_live_');
    executor = LocalCommandExecutor();
    // Replicate the app's probe (localEnvironmentProvider.ensure()) so argv
    // rewriting and the augmented PATH behave exactly as in the GUI app.
    final env = await EnvironmentResolver(executor).resolve(tempDir.path);
    executor.configureEnvironment(path: env.path, binaries: env.found);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// init -b main + README + commit, like the create-repo sheet's local steps.
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
    for (final argv in [
      ['git', 'add', '--', 'README.md'],
      ['git', 'commit', '-m', 'Initial commit'],
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

  group('GitLab live issue wire', () {
    test(
      'create project → create issues (one empty-desc) → list → view → '
      'milestone REST → delete',
      () async {
        if (!await _cliReady('glab')) {
          markTestSkipped('glab not installed/authenticated');
          return;
        }
        final host = await _glabHost() ?? 'gitlab.com';
        final name =
            'magicgit-issuewire-${DateTime.now().millisecondsSinceEpoch}';
        final dest = await initLocalRepo(name);
        final glab = GlabService(executor);
        String? projectPathForCleanup;

        try {
          // A throwaway project to mutate; wiring origin is what lets glab
          // infer the project for every issue/milestone call, exactly as in
          // the app.
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
          expect(url, isNotNull, reason: resolved.detail);
          final m = RegExp('([^/:]+)/$name').firstMatch(url!);
          projectPathForCleanup = m == null ? name : '${m.group(1)}/$name';
          final add = await executor.execute(
            repoPath: dest,
            gitArgs: ['git', 'remote', 'add', 'origin', url],
            retries: 0,
          );
          expect(add.isSuccess, isTrue, reason: add.stderr);

          // THE key unverified behavior: no --description, no PTY — glab must
          // create non-interactively from --title alone.
          await glab.createIssue(dest, title: 'Empty-description issue');
          await glab.createIssue(
            dest,
            title: 'Full issue',
            description: 'Body text from the live wire test.',
            labels: ['livewire'],
          );

          final listed = await glab.listIssues(dest);
          final empty = listed.firstWhere(
            (i) => i.title == 'Empty-description issue',
            orElse: () => fail('empty-desc issue missing from list: '
                '${listed.map((i) => i.title).toList()}'),
          );
          final full = listed.firstWhere(
            (i) => i.title == 'Full issue',
            orElse: () => fail('full issue missing from list'),
          );
          expect(empty.id, isNotNull, reason: 'list rows must carry iid');
          expect(full.labels, contains('livewire'),
              reason: 'list rows must carry bare-string label names');

          // Detail view: `--output json`, `description` → body.
          final fullDetail = await glab.issueDetail(dest, full.id!);
          expect(fullDetail.title, 'Full issue');
          expect(fullDetail.body, contains('Body text from the live wire'));
          final emptyDetail = await glab.issueDetail(dest, empty.id!);
          expect(emptyDetail.title, 'Empty-description issue');
          expect(
            emptyDetail.body == null || emptyDetail.body!.trim().isEmpty,
            isTrue,
            reason: 'an empty description must parse as null/empty, '
                'got: ${emptyDetail.body}',
          );

          // Milestone REST: create one via the passthrough, then list with
          // the app's exact call (state=active + include_ancestors).
          await glab.api(
            dest,
            'projects/:id/milestones',
            fields: ['title=live-wire-v1', 'description=live milestone'],
            method: 'POST',
          );
          final milestones = await glab.listMilestones(dest);
          final ms = milestones.firstWhere(
            (x) => x.title == 'live-wire-v1',
            orElse: () => fail('created milestone missing from list: '
                '${milestones.map((x) => x.title).toList()}'),
          );
          expect(ms.id, isNotNull,
              reason: 'fromGlabRest keys on the global id');
          expect(ms.description, 'live milestone');
          expect(ms.state, 'active');
        } finally {
          // Always delete the live project (its issues/milestones go with
          // it), even when an expect above failed.
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
            if (!del.isSuccess) {
              // ignore: avoid_print
              print('WARNING: could not delete $projectPathForCleanup: '
                  '${del.stderr}');
            }
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('GitHub live issue wire (non-mutating half)', () {
    test('list issues/milestones and view a body against an existing repo',
        () async {
      if (!await _cliReady('gh')) {
        markTestSkipped('gh not installed/authenticated');
        return;
      }
      final host = await _ghHost() ?? 'github.com';
      final gh = GhService(executor);

      // The user's newest repo stands in for the connected one.
      final list = await executor.execute(
        repoPath: tempDir.path,
        gitArgs: [
          'gh', 'repo', 'list', '--json', 'url', '--limit', '1',
          '--jq', '.[0].url',
        ],
        extraEnv: GhService.hostEnv(host),
        retries: 0,
      );
      final https = list.stdout.trim();
      if (!list.isSuccess || https.isEmpty) {
        markTestSkipped('no repos on the account to probe');
        return;
      }

      final dest = await initLocalRepo('gh-issue-probe');
      final add = await executor.execute(
        repoPath: dest,
        gitArgs: ['git', 'remote', 'add', 'origin', '$https.git'],
        retries: 0,
      );
      expect(add.isSuccess, isTrue, reason: add.stderr);

      // Shape checks: the calls must succeed and parse — an empty repo
      // legitimately yields empty lists.
      final issues = await gh.listIssues(dest);
      for (final i in issues) {
        expect(i.title, isNotEmpty);
        expect(i.id, isNotNull, reason: 'gh list rows must carry number');
      }
      final milestones = await gh.listMilestones(dest);
      for (final ms in milestones) {
        expect(ms.title, isNotEmpty);
      }
      // Detail (body field) only when the repo actually has an issue.
      if (issues.isNotEmpty) {
        final detail = await gh.issueDetail(dest, issues.first.id!);
        expect(detail.title, issues.first.title);
        // body may be empty — the point is `--json body` parses.
      } else {
        // ignore: avoid_print
        print('note: newest repo has no open issues; '
            'gh issue view left unexercised');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
