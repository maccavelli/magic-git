// The combined status/refs/remotes/pending snapshot and its marker-collision
// fallback: a commit subject (or path) containing the in-band section marker
// makes the combined stdout unsplittable — the service must recover with
// per-section round trips, not wedge the repo's status pane on a thrown
// "malformed output".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _sep = 'RMGSNAP';

/// A refs line in _refsFormat order: twelve fixed fields, subject, trailing NUL.
String _refLine(String name, String subject) =>
    '${['*', name, 'aaa', '', '', '', '', '', '', '', '', '', subject].join('\u0000')}\u0000';

String _combined({required String refsSection}) => [
  '', // status stdout (clean tree)
  '0',
  refsSection,
  '0',
  'origin\n',
  '0',
  'none',
].join(_sep);

class _QueueExecutor extends SSHCommandExecutor {
  _QueueExecutor() : super(SSHClientManager());
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];

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
    return results.isNotEmpty
        ? results.removeAt(0)
        : const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  late _QueueExecutor exec;
  late GitService git;

  setUp(() {
    exec = _QueueExecutor();
    git = GitService(exec);
  });

  test('a well-formed combined snapshot is one round trip', () async {
    exec.results.add(
      SSHCommandResult(
        exitCode: 0,
        stdout: _combined(refsSection: '${_refLine('refs/heads/main', 's')}\n'),
        stderr: '',
      ),
    );
    final refs = await git.refs('/repo');
    expect(exec.calls, hasLength(1));
    expect(refs.single.name, 'refs/heads/main');
  });

  test('a marker collision falls back to per-section round trips instead of '
      'throwing', () async {
    // The marker bytes inside a commit subject split the combined stdout into
    // extra sections — unrecoverable by any split.
    exec.results.add(
      SSHCommandResult(
        exitCode: 0,
        stdout: _combined(
          refsSection: '${_refLine('refs/heads/main', 'evil $_sep subject')}\n',
        ),
        stderr: '',
      ),
    );
    // The fallback's own four calls: status, for-each-ref, remote, pending-op.
    exec.results.addAll(const [
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      SSHCommandResult(exitCode: 0, stdout: 'origin\n', stderr: ''),
      SSHCommandResult(exitCode: 0, stdout: 'merge\n', stderr: ''),
    ]);

    final snapshotPending = await git.pendingOp('/repo');
    expect(snapshotPending, PendingOp.merge);
    expect(exec.calls, hasLength(5), reason: 'combined + 4 section fetches');
    expect(exec.calls[1].sublist(0, 2), ['git', '--no-optional-locks']);
    expect(exec.calls[2], contains('for-each-ref'));
    expect(exec.calls[3], ['git', 'remote']);
    expect(exec.calls[4].sublist(0, 2), ['sh', '-c']);
  });

  test('the fallback surfaces a real per-section failure precisely', () async {
    exec.results.add(
      // Truncated combined output (script died early) — also takes the
      // fallback path.
      const SSHCommandResult(exitCode: 1, stdout: 'garbage', stderr: ''),
    );
    exec.results.addAll(const [
      SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository',
      ),
    ]);
    await expectLater(
      () => git.status('/repo'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          'git status failed',
        ),
      ),
    );
  });

  test('a large ref section parses off-isolate, identically', () async {
    // 0023 B8. The porcelain parse was gated at 32 KiB and the ref parse
    // beside it never was — despite `for-each-ref` over heads + remotes + tags
    // routinely being the larger section, and despite running on every
    // snapshot. Crossing the threshold must change only WHERE it parses.
    String section(int count) => [
      for (var i = 0; i < count; i++)
        _refLine('refs/heads/branch-$i', 'subject number $i'),
    ].join('\n');

    final large = section(1200);
    expect(
      large.length,
      greaterThan(32 * 1024),
      reason: 'the fixture must actually cross the gate it is testing',
    );

    exec.results.add(
      SSHCommandResult(
        exitCode: 0,
        stdout: _combined(refsSection: large),
        stderr: '',
      ),
    );
    final refs = await git.refs('/repo');

    expect(exec.calls, hasLength(1), reason: 'still one round trip');
    expect(refs, hasLength(1200));
    expect(refs.first.name, 'refs/heads/branch-0');
    expect(refs.last.name, 'refs/heads/branch-1199');
    expect(refs[7].subject, 'subject number 7');
  });

  test(
    'the ref parse is gated to a background isolate, like the status parse',
    () {
      // The behavioural test above cannot see this: gating changes only WHERE
      // the parse runs, so it passes with or without the gate (verified — the
      // sabotage run was green). What it does establish is that a >32 KiB
      // payload survives the isolate hop intact, i.e. RefsResult/GitRef really
      // are sendable and nothing is dropped or reordered.
      //
      // The gate itself has no behavioural signature, so it is pinned
      // structurally — the same idiom repo_mutation_refresh_test uses for
      // invariants that live in the shape of the code rather than its output.
      final src = File('lib/core/git/git_service.dart').readAsStringSync();
      // A fixed window from the method's start — same idiom as
      // repo_mutation_refresh_test's autoFetchProvider scan. (Not a substring
      // between two markers: _fetchSnapshotSeparately is defined BEFORE
      // _assembleSnapshot, so that range inverts.)
      final start = src.indexOf('Future<RepoSnapshot> _assembleSnapshot(');
      expect(start, greaterThan(0));
      final assemble = src.substring(start, start + 3000);
      expect(
        assemble,
        contains('Isolate.run(() => parseRefsDetailed'),
        reason:
            'the ref section is routinely LARGER than the status section; '
            'parsing it inline is the one thing on this path that can stall '
            'frames rather than merely spin a pane',
      );
      expect(assemble, contains('refsStdout.length > _isolateThreshold'));
    },
  );
}
