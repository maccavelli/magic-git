// Branch-protection enrichment (plan 0003 §3.7), which was never built.
//
// The load-bearing property is the third state. Protection is the difference
// between a delete that fails and one that succeeds, and forges report it
// unevenly — GitHub rulesets are invisible to the branches API, GitLab needs a
// separate call, either can fail. Reporting "we could not find out" as
// "unprotected" would turn a missing answer into a green light.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/branch_review_query.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor() : super(SSHClientManager());
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];
  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    calls.add(gitArgs);
    return results.isNotEmpty ? results.removeAt(0) : next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

// glab api rides `-i`, so its bodies carry an HTTP header block.
SSHCommandResult _glab(String body, {int status = 200}) =>
    _ok('HTTP/2.0 $status\r\n\r\n$body');

const _repo = '/repo';

void main() {
  late _FakeExecutor exec;
  late GhService gh;
  late GlabService glab;

  setUp(() {
    exec = _FakeExecutor();
    gh = GhService(exec);
    glab = GlabService(exec);
  });

  group('ProtectionKnowledge', () {
    test('an unavailable fetch reports unknown, never unprotected', () {
      const rules = BranchProtectionRules.unavailable;

      expect(rules.protectionFor('main').isUnknown, isTrue);
      expect(
        rules.protectionFor('main').isProtected,
        isFalse,
        reason: 'unknown is not protected either — it is simply unknown',
      );
    });

    test('a known answer separates protected from unprotected', () {
      const rules = BranchProtectionRules(names: {'main'}, known: true);

      expect(rules.protectionFor('main').isProtected, isTrue);
      expect(rules.protectionFor('feature'), isA<ProtectionUnprotected>());
      expect(rules.protectionFor('feature').isUnknown, isFalse);
    });

    test('GitLab patterns match by wildcard, GitHub names by equality', () {
      const gitlab = BranchProtectionRules(
        patterns: ['release/*'],
        known: true,
      );
      expect(gitlab.protectionFor('release/1.0').isProtected, isTrue);
      expect(gitlab.protectionFor('feature/1.0').isProtected, isFalse);

      const github = BranchProtectionRules(names: {'release/1.0'}, known: true);
      expect(github.protectionFor('release/1.0').isProtected, isTrue);
      expect(
        github.protectionFor('release/2.0').isProtected,
        isFalse,
        reason: 'GitHub returns literal names, so no wildcard expansion',
      );
    });

    test('a wildcard crosses path separators, as GitLab does', () {
      // The doc comment used to claim segment-scoped matching; the
      // implementation never did that, and GitLab does not either.
      expect(
        gitlabProtectedBranchMatches('release/*', 'release/1.0/hotfix'),
        isTrue,
      );
    });
  });

  group('GhService.protectedBranchNames', () {
    test('asks the LIST endpoint, not per-branch protection', () async {
      exec.results.add(_ok('[{"name":"main","protected":true}]'));

      final names = await gh.protectedBranchNames(_repo, perPage: 100);

      expect(names, ['main']);
      // Per-branch /protection is one call per branch AND 403s for
      // non-admins, which would report "unknown" on a repo whose protection
      // is plainly visible.
      expect(exec.calls.single, [
        'gh',
        'api',
        'repos/{owner}/{repo}/branches',
        '--method',
        'GET',
        '-f',
        'protected=true',
        '-f',
        'per_page=100',
        '-f',
        'page=1',
      ]);
    });

    test('walks pages by hand until a short page, never --paginate', () async {
      exec.results.addAll([
        _ok('[{"name":"a"},{"name":"b"}]'), // full page
        _ok('[{"name":"c"}]'), // short page → stop
      ]);

      final names = await gh.protectedBranchNames(_repo, perPage: 2);

      expect(names, ['a', 'b', 'c']);
      expect(exec.calls.length, 2);
      expect(
        exec.calls.every((c) => !c.contains('--paginate')),
        isTrue,
        reason: 'gh --paginate emits one array per page — invalid JSON to a '
            'single decode',
      );
    });

    test('a non-array body throws rather than reading as "none protected"',
        () async {
      exec.results.add(_ok('{"message":"Not Found"}'));

      await expectLater(
        gh.protectedBranchNames(_repo),
        throwsA(isA<GhException>()),
      );
    });
  });

  group('GlabService.protectedBranchPatterns', () {
    test('hand-walks with per_page/page so it can keep the -i status check',
        () async {
      exec.results.add(_glab('[{"name":"release/*"}]'));

      final patterns = await glab.protectedBranchPatterns(_repo, perPage: 100);

      expect(patterns, ['release/*']);
      final call = exec.calls.single;
      expect(call, contains('projects/:id/protected_branches'));
      expect(
        call,
        contains('-i'),
        reason: "glab's exit codes are advisory; the HTTP status is the "
            'authority, and --paginate would force dropping it',
      );
      expect(call, isNot(contains('--paginate')));
    });

    test('an HTTP 403 throws instead of reading as "no protected branches"',
        () async {
      exec.results.add(_glab('{"message":"403 Forbidden"}', status: 403));

      await expectLater(
        glab.protectedBranchPatterns(_repo),
        throwsA(isA<GlabException>()),
      );
    });
  });
}
