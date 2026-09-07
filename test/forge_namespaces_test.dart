// MADR 0031 Phase 1 — the namespaces an account may create a project in.
//
// Host-explicit on both forges: at create time the project does not exist, so
// there is no origin to infer a host from. That is the whole reason these do
// not reuse the ambient-host paths.
//
// The failure contract is as load-bearing as the success one. A create sheet
// whose namespace field is free text does not need this list to work, so an
// API that 404s, times out, or answers with HTML must yield an empty list and
// let the user type — never throw into the sheet.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<Map<String, String>?> envs = [];
  final List<SSHCommandResult> results = [];

  /// Answers by REQUEST rather than by queue position. Concurrent calls
  /// (`Future.wait` over several access floors) interleave in an order the
  /// test cannot predict, so a positional queue silently hands the wrong page
  /// to the wrong floor. Takes precedence over [results] when set.
  SSHCommandResult Function(List<String> args)? respond;

  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    calls.add(gitArgs);
    envs.add(extraEnv);
    final router = respond;
    if (router != null) return router(gitArgs);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// `glab api -i` output: header block, blank line, then the body.
SSHCommandResult _okWithHeaders(String body) =>
    _ok('HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n$body');

void main() {
  group('GlabService.listCreatableNamespaces', () {
    test('own namespace first, then groups by full path', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.results.addAll([
        _okWithHeaders('{"username":"testuser"}'),
        _okWithHeaders(
          '[{"full_path":"team/subgroup"},{"full_path":"platform"}]',
        ),
      ]);

      final namespaces = await glab.listCreatableNamespaces(
        '/repo',
        host: 'gitlab.example',
      );

      expect(namespaces, ['testuser', 'team/subgroup', 'platform']);
    });

    test('asks for groups the account can actually create in', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.results.addAll([
        _okWithHeaders('{"username":"testuser"}'),
        _ok('[]'), // three floors, each an empty (short) page
        _ok('[]'),
        _ok('[]'),
      ]);

      await glab.listCreatableNamespaces('/repo', host: 'gitlab.example');

      final groupCalls = [
        for (final c in exec.calls)
          if (c.contains('groups')) c.join(' '),
      ];
      // Three concurrent floors, not one: `min_access_level=30` alone is not
      // GitLab's create gate — the group's own `project_creation_level` is, and
      // deciding needs the account's actual access (MADR 0032 Phase 2).
      expect(groupCalls, hasLength(3));
      expect(
        groupCalls.map(
          (c) => RegExp(r'min_access_level=(\d+)').firstMatch(c)!.group(1),
        ),
        containsAll(<String>['30', '40', '50']),
      );
      for (final call in groupCalls) {
        // `namespaces` lists what the account can SEE, including other people's
        // personal namespaces it cannot create in. Verified live; MADR 0031.
        expect(call, isNot(contains('namespaces')));
        // No origin exists yet, so the host must be explicit.
        expect(call, contains('gitlab.example'));
      }
    });

    test('a failing groups call still yields the own namespace', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.results.addAll([
        _okWithHeaders('{"username":"testuser"}'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: '404'),
      ]);

      expect(
        await glab.listCreatableNamespaces('/repo', host: 'gitlab.example'),
        ['testuser'],
      );
    });

    test('non-JSON answers yield an empty list rather than throwing', () async {
      final exec = _FakeExecutor();
      final glab = GlabService(exec);
      exec.next = _ok('<html>gateway timeout</html>');

      expect(
        await glab.listCreatableNamespaces('/repo', host: 'gitlab.example'),
        isEmpty,
      );
    });
  });

  group('GhService.listCreatableNamespaces', () {
    test('login first, then organisation logins', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.results.addAll([
        _ok('{"login":"testuser"}'),
        _ok('[{"login":"acme-eng"},{"login":"acme-infra"}]'),
      ]);

      final namespaces = await gh.listCreatableNamespaces(
        '/repo',
        host: 'github.com',
      );

      expect(namespaces, ['testuser', 'acme-eng', 'acme-infra']);
    });

    test('a non-default host is selected via GH_HOST', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.results.addAll([_ok('{"login":"testuser"}'), _ok('[]')]);

      await gh.listCreatableNamespaces('/repo', host: 'ghe.example');

      // `every` on an empty list is vacuously true, so pin the call count
      // first — this assertion passed against the empty stub without it.
      expect(exec.envs, hasLength(2));
      expect(exec.envs.every((e) => e?['GH_HOST'] == 'ghe.example'), isTrue);
    });

    test('a failing orgs call still yields the login', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.results.addAll([
        _ok('{"login":"testuser"}'),
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      ]);

      expect(await gh.listCreatableNamespaces('/repo', host: 'github.com'), [
        'testuser',
      ]);
    });

    test('non-JSON answers yield an empty list rather than throwing', () async {
      final exec = _FakeExecutor();
      final gh = GhService(exec);
      exec.next = _ok('not json at all');

      expect(
        await gh.listCreatableNamespaces('/repo', host: 'github.com'),
        isEmpty,
      );
    });
  });

  group('GhService.listCreatableNamespaces pagination (MADR 0034 F7)', () {
    String orgsPage(int n, {required int from}) =>
        '[${[for (var i = from; i < from + n; i++) '{"login":"org$i"}'].join(',')}]';

    test('walks past the first page instead of truncating at 100', () async {
      final exec = _FakeExecutor();
      exec.results
        ..add(_ok('{"login":"me"}')) // gh api user
        ..add(_ok(orgsPage(100, from: 0))) // full page -> keep going
        ..add(_ok(orgsPage(3, from: 100))); // short page -> stop
      final gh = GhService(exec);

      final namespaces = await gh.listCreatableNamespaces(
        '/repo',
        host: 'github.com',
      );

      expect(namespaces.length, 104, reason: 'login + 103 orgs');
      expect(namespaces.first, 'me');
      expect(
        namespaces.last,
        'org102',
        reason: 'the tail past the first page must be offered',
      );
    });

    test('asks for a real page number, not a literal', () async {
      // Regression for a `\\$page` that reached the argv as the literal text
      // rather than the value — the analyzer accepts it and the API would
      // simply return page 1 forever.
      final exec = _FakeExecutor();
      exec.results
        ..add(_ok('{"login":"me"}'))
        ..add(_ok(orgsPage(100, from: 0)))
        ..add(_ok(orgsPage(1, from: 100)));
      await GhService(
        exec,
      ).listCreatableNamespaces('/repo', host: 'github.com');

      final orgCalls = exec.calls
          .where((c) => c.contains('user/orgs'))
          .toList();
      expect(orgCalls, hasLength(2));
      expect(orgCalls[0], containsAll(<String>['per_page=100', 'page=1']));
      expect(orgCalls[1], containsAll(<String>['per_page=100', 'page=2']));
    });

    test('a single short page issues exactly one orgs call', () async {
      final exec = _FakeExecutor();
      exec.results
        ..add(_ok('{"login":"me"}'))
        ..add(_ok(orgsPage(2, from: 0)));
      await GhService(
        exec,
      ).listCreatableNamespaces('/repo', host: 'github.com');

      expect(
        exec.calls.where((c) => c.contains('user/orgs')),
        hasLength(1),
        reason: 'the common case must not pay for a second round trip',
      );
    });
  });

  group('GlabService creatable filter (MADR 0032 Phase 2)', () {
    /// One `/groups` page. `level` is the group's `project_creation_level`.
    String page(List<(String path, String? level)> groups) =>
        '[${groups.map((g) => '{"full_path":"${g.$1}"'
            '${g.$2 == null ? '' : ',"project_creation_level":"${g.$2}"'}}').join(',')}]';

    /// Routes by REQUEST, not by queue position: `Future.wait` interleaves the
    /// access floors in an order the test cannot predict, so a positional queue
    /// silently hands the wrong page to the wrong floor.
    void route(
      _FakeExecutor exec, {
      List<String> at30 = const [],
      List<String> at40 = const [],
      List<String> at50 = const [],
      Map<String, String?> levels = const {},
      Map<String, List<List<String>>> pagesAt30 = const {},
    }) {
      List<(String, String?)> rows(List<String> paths) => [
        for (final p in paths) (p, levels[p]),
      ];
      exec.respond = (args) {
        final joined = args.join(' ');
        if (!joined.contains('groups')) {
          return _okWithHeaders('{"username":"me"}');
        }
        final floor =
            RegExp(r'min_access_level=(\d+)').firstMatch(joined)?.group(1) ??
            '30';
        final pageNo =
            int.tryParse(
              // NOT `page=(\d+)`: that matches `per_page=100` first, so every
              // request reads as page 100 and the walk looks finished.
              RegExp(r'(?<![a-z_])page=(\d+)').firstMatch(joined)?.group(1) ??
                  '1',
            ) ??
            1;
        final override = pagesAt30[floor];
        if (override != null) {
          return _ok(
            page(
              rows(pageNo <= override.length ? override[pageNo - 1] : const []),
            ),
          );
        }
        if (pageNo > 1) return _ok(page(const []));
        return _ok(
          page(
            rows(switch (floor) {
              '30' => at30,
              '40' => at40,
              _ => at50,
            }),
          ),
        );
      };
    }

    test(
      'excludes a group whose creation level outranks the account',
      () async {
        // NOT reproducible on the maintainer's own account — it holds Owner on
        // every group, so 30/40/50 all return the same list and nothing is ever
        // filtered. A fixture is the only way to prove this arm (MADR 0032).
        final exec = _FakeExecutor();
        route(
          exec,
          at30: ['team/dev-ok', 'team/needs-maintainer'],
          at40: ['team/dev-ok'], // account is Maintainer here, Developer there
          at50: const <String>[],
          levels: {
            'team/dev-ok': 'developer',
            'team/needs-maintainer': 'maintainer',
          },
        );

        final namespaces = await GlabService(
          exec,
        ).listCreatableNamespaces('/repo', host: 'gitlab.example');

        expect(namespaces, ['me', 'team/dev-ok']);
      },
    );

    test(
      'keeps a maintainer-level group when the account is a Maintainer',
      () async {
        final exec = _FakeExecutor();
        route(
          exec,
          at30: ['team/needs-maintainer'],
          at40: ['team/needs-maintainer'],
          at50: const <String>[],
          levels: {'team/needs-maintainer': 'maintainer'},
        );

        final namespaces = await GlabService(
          exec,
        ).listCreatableNamespaces('/repo', host: 'gitlab.example');

        expect(namespaces, ['me', 'team/needs-maintainer']);
      },
    );

    test('a null creation level is treated as permissive', () async {
      // Hiding a usable group is worse than a create failure the user can
      // retry, so an absent level must not filter.
      final exec = _FakeExecutor();
      route(
        exec,
        at30: ['team/unknown-level'],
        at40: const <String>[],
        at50: const <String>[],
        levels: {'team/unknown-level': null},
      );

      final namespaces = await GlabService(
        exec,
      ).listCreatableNamespaces('/repo', host: 'gitlab.example');

      expect(namespaces, ['me', 'team/unknown-level']);
    });

    test('a `noone` group is never offered', () async {
      final exec = _FakeExecutor();
      route(
        exec,
        at30: ['team/locked'],
        at40: ['team/locked'],
        at50: ['team/locked'], // even as Owner
        levels: {'team/locked': 'noone'},
      );

      final namespaces = await GlabService(
        exec,
      ).listCreatableNamespaces('/repo', host: 'gitlab.example');

      expect(namespaces, ['me']);
    });

    test('walks past the first page of groups', () async {
      // A single per_page=100 silently dropped everything past the hundredth.
      final exec = _FakeExecutor();
      final full = [for (var i = 0; i < 100; i++) 'team/g$i'];
      route(
        exec,
        levels: {
          for (final p in [...full, 'team/tail']) p: 'developer',
        },
        pagesAt30: {
          '30': [
            full,
            const ['team/tail'],
          ],
        },
      );

      final namespaces = await GlabService(
        exec,
      ).listCreatableNamespaces('/repo', host: 'gitlab.example');

      expect(namespaces.length, 102, reason: 'login + 101 groups');
      expect(namespaces.last, 'team/tail');
      expect(
        exec.calls.where((c) => c.contains('groups')).length,
        greaterThanOrEqualTo(4),
        reason: 'floor 30 needed two pages; 40 and 50 one each',
      );
    });
  });
}
