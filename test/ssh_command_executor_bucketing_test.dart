// MADR 0039 H1/H3 — the executor half of the adaptive-controller fix.
//
// `adaptive_read_concurrency_test.dart` pins the control law. These pin the two
// things only the executor can get wrong: which bucket a command's sample is
// filed under, and which lane's successes are allowed to lift the channel-open
// error floor.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/adaptive_read_concurrency.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/fake_ssh_client.dart';

/// An executor whose commands take a measurable moment.
///
/// `hangExecute` holds the command open until [_run] releases it, which is what
/// makes `sw.elapsed` non-zero: the controller drops a zero-microsecond sample
/// as nonsense, and against an instant fake every real command would be one.
({SSHCommandExecutor executor, FakeSshClient client}) _executor({
  bool hang = false,
}) {
  final manager = SSHClientManager();
  final executor = SSHCommandExecutor(manager);
  final client = FakeSshClient(hangExecute: hang);
  manager.bindTestClients(command: client);
  return (executor: executor, client: client);
}

/// Runs one read-lane command that takes long enough to be sampled.
Future<void> _read(
  ({SSHCommandExecutor executor, FakeSshClient client}) e,
  List<String> gitArgs,
) async {
  final future = e.executor.execute(
    repoPath: '/r',
    gitArgs: gitArgs,
    lane: ExecLane.read,
  );
  await Future<void>.delayed(const Duration(milliseconds: 2));
  e.client.completeExecute();
  await future;
}

void main() {
  test('a read is filed under its NORMALISED command', () async {
    // Two spellings of the same read: the refs fetch carries
    // `-c i18n.logOutputEncoding=UTF-8` and the plain form does not, and their
    // `--format` strings differ. `bucketLabel` collapses both, which is the
    // whole reason the executor calls it rather than keying on raw argv — two
    // buckets for one command would halve each bucket's sample count and
    // stretch its warm-up.
    final e = _executor(hang: true);

    await _read(e, [
      'git',
      '-c',
      'i18n.logOutputEncoding=UTF-8',
      'for-each-ref',
      '--format=%(refname)',
    ]);
    await _read(e, ['git', 'for-each-ref', '--format=%(objectname)']);

    final executor = e.executor;
    expect(
      executor.adaptiveReads.gradientFor('git for-each-ref --format=…'),
      isNotNull,
      reason:
          'the sample must be filed under CommandTelemetry.bucketLabel, or '
          'a rev-list batch ends up compared against a rev-parse',
    );
    expect(executor.adaptiveReads.gradientFor('(all)'), isNull);
    expect(
      executor.adaptiveReads.bucketCount,
      1,
      reason: 'both spellings are one command',
    );
  });

  test('two different commands are two buckets', () async {
    final e = _executor(hang: true);

    await _read(e, ['git', 'status']);
    await _read(e, ['sh', '-c', 'for oid; do git rev-list; done']);

    final executor = e.executor;
    expect(executor.adaptiveReads.bucketCount, 2);
    expect(executor.adaptiveReads.gradientFor('git status'), isNotNull);
    expect(
      executor.adaptiveReads.gradientFor('sh -c'),
      isNotNull,
      reason:
          'every shell wrapper collapses to one bucket — their scripts are '
          'unique per call, so bucketing on them would defeat the point',
    );
  });

  test('a non-read command records no sample at all', () async {
    final e = _executor(hang: true);

    // Default lane is exclusive.
    final future = e.executor.execute(
      repoPath: '/r',
      gitArgs: ['git', 'commit'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    e.client.completeExecute();
    await future;
    final executor = e.executor;

    expect(
      executor.adaptiveReads.bucketCount,
      0,
      reason:
          'a commit says nothing about how many parallel READS the host '
          'will serve — it is not evidence for this controller',
    );
  });
  test('only a read-lane success lifts the error floor', () async {
    // The controller is injected with a clock the test owns: the dwell H3 adds
    // is tens of seconds, and while it holds NO lane's successes lift the
    // floor — so without stepping past it, this test cannot tell the read-lane
    // guard from the hold, and the mutation that removes the guard survives.
    var now = DateTime(2026);
    final adaptive = AdaptiveReadConcurrency(now: () => now);
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager, adaptiveReads: adaptive);
    manager.bindTestClients(command: FakeSshClient());

    adaptive.onChannelOpenError();
    final floored = executor.adaptiveReadCap;
    expect(floored, lessThan(4));

    // Step past the dwell, so the only thing left holding the floor down is
    // the absence of read-lane successes.
    now = now.add(AdaptiveReadConcurrency.baseFloorDwell * 2);

    // Successful MUTATIONS, well past the recovery streak.
    for (var i = 0; i < 6; i++) {
      await executor.execute(repoPath: '/r', gitArgs: ['git', 'commit']);
    }

    expect(
      executor.adaptiveReadCap,
      floored,
      reason:
          'onSuccess used to sit outside the read-lane guard, so a commit '
          'lifted the floor and the next read was refused again — the '
          'oscillation H3 exists to stop',
    );

    // The control: a read does lift it.
    final future = executor.execute(
      repoPath: '/r',
      gitArgs: ['git', 'status'],
      lane: ExecLane.read,
    );
    await future;
    for (var i = 0; i < 2; i++) {
      await executor.execute(
        repoPath: '/r',
        gitArgs: ['git', 'status'],
        lane: ExecLane.read,
      );
    }
    expect(
      executor.adaptiveReadCap,
      greaterThan(floored),
      reason: 'read-lane successes are the evidence the floor answers to',
    );
  });
}
