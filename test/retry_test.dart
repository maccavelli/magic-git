// The transient-failure retry policy: SSHCommandExecutor.runWithRetries retries
// transient transport errors but never a timeout, and GitService opts idempotent
// reads (not mutations) into a retry.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _RetryCapturingExecutor extends SSHCommandExecutor {
  _RetryCapturingExecutor() : super(SSHClientManager());
  final List<int> retriesSeen = [];
  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  // GitService.status bundles status/refs/pendingOp into one combined `sh -c`
  // round trip (see GitService._fetchSnapshot) — recognized here so `next`
  // (used by every other read/write in this test) doesn't need to itself be
  // shaped like that combined output.
  static const _sep = 'RMGSNAP';
  static const _emptySnapshot = '$_sep' '0$_sep' '$_sep' '0$_sep' 'none\n';

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
  }) async {
    retriesSeen.add(retries);
    if (gitArgs.length == 3 && gitArgs[0] == 'sh' && gitArgs[1] == '-c') {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: _emptySnapshot,
        stderr: '',
      );
    }
    return next;
  }
}

void main() {
  group('runWithRetries policy', () {
    test('retries a transient failure, then succeeds', () async {
      var calls = 0;
      final r = await SSHCommandExecutor.runWithRetries(() async {
        calls++;
        if (calls < 3) throw Exception('SSH connection not established.');
        return const SSHCommandResult(exitCode: 0, stdout: 'ok', stderr: '');
      }, 3, backoff: Duration.zero);
      expect(calls, 3);
      expect(r.stdout, 'ok');
    });

    test('gives up after exhausting the retry budget', () async {
      var calls = 0;
      await expectLater(
        SSHCommandExecutor.runWithRetries(
          () async {
            calls++;
            throw Exception('down');
          },
          1,
          backoff: Duration.zero,
        ),
        throwsA(isA<Exception>()),
      );
      expect(calls, 2); // initial attempt + one retry
    });

    test('never retries a timeout (ambiguous — may have run)', () async {
      var calls = 0;
      await expectLater(
        SSHCommandExecutor.runWithRetries(
          () async {
            calls++;
            throw const SSHCommandTimeout('git push');
          },
          5,
          backoff: Duration.zero,
        ),
        throwsA(isA<SSHCommandTimeout>()),
      );
      expect(calls, 1);
    });

    test(
      'never retries a superseded command (retrying would just fail again '
      'against the same stale generation)',
      () async {
        var calls = 0;
        await expectLater(
          SSHCommandExecutor.runWithRetries(
            () async {
              calls++;
              throw const SSHCommandSuperseded('git status');
            },
            5,
            backoff: Duration.zero,
          ),
          throwsA(isA<SSHCommandSuperseded>()),
        );
        expect(calls, 1);
      },
    );

    test(
      "a retry's backoff does not head-of-line-block later queued commands",
      () async {
        // A serialization tail identical to the executors': every attempt
        // links onto it, errors swallowed on the tail so a failure doesn't
        // wedge the queue.
        Future<void> tail = Future.value();
        Future<SSHCommandResult> enqueue(
          Future<SSHCommandResult> Function() attempt,
        ) {
          final result = tail.then((_) => attempt());
          tail = result.then((_) {}, onError: (_) {});
          return result;
        }

        final order = <String>[];

        // Command A fails once (transient), then succeeds — with a real 100ms
        // backoff between the two attempts.
        var aCalls = 0;
        final a = SSHCommandExecutor.runWithRetries(
          () async {
            aCalls++;
            order.add('A#$aCalls');
            if (aCalls == 1) throw Exception('transient');
            return const SSHCommandResult(exitCode: 0, stdout: 'a', stderr: '');
          },
          1,
          backoff: const Duration(milliseconds: 100),
          enqueue: enqueue,
        );

        // Command B is enqueued immediately behind A's first attempt.
        final b = enqueue(() async {
          order.add('B');
          return const SSHCommandResult(exitCode: 0, stdout: 'b', stderr: '');
        });

        await Future.wait([a, b]);

        // A's first attempt runs and fails; the slot is released so B runs
        // during A's backoff; A's retry re-enqueues at the back and runs last.
        // With the backoff held inside the slot (the old behavior) B would be
        // stuck behind the whole retry loop → ['A#1', 'A#2', 'B'].
        expect(order, ['A#1', 'B', 'A#2']);
        expect(aCalls, 2);
      },
    );
  });

  group('GitService opts reads (not mutations) into retry', () {
    late _RetryCapturingExecutor exec;
    late GitService git;
    setUp(() {
      exec = _RetryCapturingExecutor();
      git = GitService(exec);
    });

    test('idempotent reads request a retry', () async {
      await git.revParse('/repo', 'HEAD');
      await git.status('/repo');
      await git.diffFile('/repo', path: 'a.dart', staged: false);
      expect(exec.retriesSeen, everyElement(greaterThan(0)));
    });

    test('mutations and network writes never retry', () async {
      await git.stage('/repo', 'a.dart');
      await git.commit('/repo', message: 'x');
      await git.push('/repo');
      await git.createTag('/repo', 'v1');
      expect(exec.retriesSeen, everyElement(0));
    });
  });
}
