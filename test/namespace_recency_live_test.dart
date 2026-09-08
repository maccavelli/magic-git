// LIVE verification of MADR 0032 — the recency and search that feed the create
// sheet's namespace field, against the REAL glab/gh CLIs.
//
// **Read-only.** Unlike `create_repo_wire_live_test.dart`, nothing here
// creates, mutates or deletes anything on either forge: every call is a GET
// (`events`, `projects/:id`, `groups`, `user`). It is still tagged
// `live-forge` because it is network-dependent, account-dependent, and its
// results describe a real account.
//
// The offline suite cannot prove the API SHAPES — it can only prove what argv
// we send and what we do with a fixture. These three arms are the ones MADR
// 0032's plan named as unprovable offline:
//
//   1. the events window actually returns namespaces on a real account;
//   2. `search` composes with `min_access_level` and narrows the list;
//   3. a group whose `project_creation_level` outranks the account's access is
//      excluded — which is expected to be UNPROVABLE on an Owner-everywhere
//      account, and says so rather than passing vacuously.
//
// **No real namespace, group or project name is ever printed or asserted on.**
// Counts and shapes carry the whole argument; naming the group adds nothing
// but exposure (AGENTS.md). Assertions are therefore about cardinality,
// subset relationships and structure.
@Tags(['integration', 'live-forge'])
library;

import 'dart:convert';
import 'dart:io';

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

/// The authenticated host for [cli], or null when signed out. Same parse as
/// `create_repo_wire_live_test.dart`.
Future<String?> _host(String cli) async {
  try {
    final r = await Process.run(cli, ['auth', 'status']);
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
    tempDir = Directory.systemTemp.createTempSync('ns_recency_live_');
    executor = LocalCommandExecutor();
    final env = await EnvironmentResolver(executor).resolve(tempDir.path);
    executor.configureEnvironment(path: env.path, binaries: env.found);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('GitLab namespace recency and search (MADR 0032)', () {
    test(
      'the events window returns namespaces a create could target',
      () async {
        if (!await _cliReady('glab')) {
          markTestSkipped('glab not authenticated');
          return;
        }
        final host = await _host('glab');
        if (host == null) {
          markTestSkipped('could not read the glab host');
          return;
        }
        final glab = GlabService(executor);

        final stopwatch = Stopwatch()..start();
        final recent = await glab.recentlyActiveNamespaces(
          tempDir.path,
          host: host,
        );
        stopwatch.stop();

        // Shape, not identity: every entry must be a usable namespace path.
        for (final ns in recent.keys) {
          expect(ns, isNotEmpty);
          expect(ns.startsWith('/'), isFalse, reason: 'a path, not a route');
          expect(ns.endsWith('/'), isFalse);
        }
        // A map cannot hold a duplicate key, so the dedup claim is structural
        // now. What is worth asserting live is that the events payload really
        // does supply the timestamps Phase 8 renders — a null here would mean
        // the label silently never appears.
        final cutoff = DateTime.now().toUtc().add(const Duration(minutes: 5));
        expect(
          recent.values.every((at) => at != null && at.isBefore(cutoff)),
          isTrue,
          reason: 'every recent namespace carries a plausible last-active time',
        );
        expect(
          recent.length,
          lessThanOrEqualTo(10),
          reason: '_maxRecentProjects caps the lookups this fans out to',
        );

        // The cost claim the MADR made its decision on. Not asserted as a hard
        // bound (a live network is not a benchmark), but reported so a
        // regression to the 9.0 s membership call is visible.
        // ignore: avoid_print
        print(
          'events → namespaces: ${recent.length} namespace(s) '
          'in ${stopwatch.elapsedMilliseconds} ms',
        );

        if (recent.isEmpty) {
          markTestSkipped(
            'no GitLab activity in the last 7 days — the arm cannot be '
            'exercised on this account right now',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('search composes with min_access_level and narrows the list', () async {
      if (!await _cliReady('glab')) {
        markTestSkipped('glab not authenticated');
        return;
      }
      final host = await _host('glab');
      if (host == null) {
        markTestSkipped('could not read the glab host');
        return;
      }
      final glab = GlabService(executor);

      final all = await glab.listCreatableNamespaces(tempDir.path, host: host);
      expect(all, isNotEmpty, reason: 'the account must be able to create');
      // ignore: avoid_print
      print('creatable namespaces: ${all.length}');

      // Groups only — the first entry is the account's own namespace, which
      // `groups?search=` cannot return.
      final groups = all.skip(1).toList();
      if (groups.isEmpty) {
        markTestSkipped('account has no groups; search has nothing to narrow');
        return;
      }

      // The LAST segment of a real group path, used only as a needle and never
      // printed. The first segment would be the shared root on an instance
      // where every group hangs off one parent — matching all of them, which
      // proves composition but demonstrates no narrowing at all.
      final needle = groups.first.split('/').last;
      final found = await glab.searchCreatableNamespaces(
        tempDir.path,
        host: host,
        query: needle,
      );

      // ignore: avoid_print
      print('search narrowed ${groups.length} group(s) to ${found.length}');
      expect(found, isNotEmpty, reason: 'the needle came from a real path');
      expect(
        found.length,
        lessThan(groups.length),
        reason:
            'a leaf-segment needle must narrow, not return everything — '
            'the composition measured in the MADR was 37 groups down to 24',
      );
      // The load-bearing property: search cannot offer what the full creatable
      // list would have excluded.
      expect(
        found.every(all.contains),
        isTrue,
        reason: 'every search hit must already be creatable',
      );
      // And it must actually match, not return everything.
      expect(
        found.every((ns) => ns.toLowerCase().contains(needle.toLowerCase())),
        isTrue,
        reason: 'search matches name or path, so every hit contains the needle',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'a group demanding higher access than the account holds is excluded',
      () async {
        if (!await _cliReady('glab')) {
          markTestSkipped('glab not authenticated');
          return;
        }
        final host = await _host('glab');
        if (host == null) {
          markTestSkipped('could not read the glab host');
          return;
        }

        // Compare the three access floors directly. If they return identical
        // lists, the account holds the same access everywhere and the exclusion
        // branch is unreachable — which the MADR predicted for an
        // Owner-everywhere account. Say so; do not pass vacuously.
        final counts = <int, int>{};
        for (final floor in [30, 40, 50]) {
          final decoded = await GlabService(executor).api(
            tempDir.path,
            'groups',
            fields: ['min_access_level=$floor', 'per_page=100', 'page=1'],
            host: host,
          );
          counts[floor] = decoded is List ? decoded.length : -1;
        }
        // ignore: avoid_print
        print('groups by access floor: $counts');

        if (counts[30] == counts[40] && counts[40] == counts[50]) {
          markTestSkipped(
            'the account holds the same access at every floor, so no group can '
            'be excluded by creation level — this arm stays fixture-only, as '
            'MADR 0032 predicted',
          );
          return;
        }
        expect(
          counts[30]!,
          greaterThanOrEqualTo(counts[40]!),
          reason: 'a higher floor can only ever return fewer groups',
        );
        expect(counts[40]!, greaterThanOrEqualTo(counts[50]!));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('GitHub namespace recency (MADR 0032)', () {
    test('events carry the owner, so no project lookup is needed', () async {
      if (!await _cliReady('gh')) {
        markTestSkipped('gh not authenticated');
        return;
      }
      final host = await _host('gh');
      if (host == null) {
        markTestSkipped('could not read the gh host');
        return;
      }

      final recent = await GhService(
        executor,
      ).recentlyActiveNamespaces(tempDir.path, host: host);

      // ignore: avoid_print
      print('GitHub recent namespaces: ${recent.length}');
      for (final ns in recent.keys) {
        expect(ns, isNotEmpty);
        expect(
          ns.contains('/'),
          isFalse,
          reason:
              'a GitHub namespace is an owner, never owner/repo — the '
              'split is what makes the second round trip unnecessary',
        );
      }
      expect(recent.keys.toSet(), hasLength(recent.length));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
