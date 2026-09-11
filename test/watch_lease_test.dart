// MADR 0045 phase 3. One watcher instance's claims on the host — its lease and
// its lock — owned by one unit instead of two closures inside the arm.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/watch_lease.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records every command; fails the `touch`, or throws, when told to.
class _Host extends SSHCommandExecutor {
  _Host({this.refuseTouch = false, this.unreachable = false})
    : super(SSHClientManager());

  final bool refuseTouch;
  final bool unreachable;
  final commands = <String>[];

  /// The argv of every command, so one can be run for real.
  final argv = <List<String>>[];

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
    final joined = gitArgs.join(' ');
    commands.add(joined);
    argv.add(gitArgs);
    if (unreachable) throw const SSHTransportNotReady('lease');
    if (refuseTouch && joined.contains('touch')) {
      return const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'touch: cannot touch: Not a directory',
      );
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

WatchLease _lease(_Host host) => WatchLease(
  executor: host,
  repoPath: '/srv/feature',
  gitDir: '/srv/main/.git/worktrees/feature',
  token: 'tok',
  timings: WatchTimings.standard,
);

void main() {
  test('the paths live in the resolved git dir', () {
    final lease = _lease(_Host());

    expect(lease.pidFile, '/srv/main/.git/worktrees/feature/mg-watch.tok.pid');
    expect(
      lease.heartbeatFile,
      '/srv/main/.git/worktrees/feature/mg-watch.tok.hb',
    );
    expect(lease.lock.gitDir, '/srv/main/.git/worktrees/feature');
    expect(lease.lock.token, 'tok');
  });

  test("a failed stamp throws with the host's reason", () async {
    final lease = _lease(_Host(refuseTouch: true));

    await expectLater(
      lease.stamp(),
      throwsA(
        isA<WatchLeaseException>().having(
          (e) => e.message,
          'message',
          contains('Not a directory'),
        ),
      ),
      reason:
          'swallowed, this opened a stream whose watcher exited at once — a '
          'restart spent learning what the command had already said',
    );
  });

  test('releasing is token-guarded and best-effort', () async {
    // EXECUTED, not matched as text: the command this lease issues is run with
    // a real `sh` against a real lock, once owned by this token and once stolen
    // from it.
    final root = await Directory.systemTemp.createTemp('mg-lease-release-');
    addTearDown(() => root.delete(recursive: true));
    final gitDir = '${root.resolveSymbolicLinksSync()}/.git';

    Future<void> releaseWithLockOwnedBy(String owner) async {
      Directory('$gitDir/mg-watch.lock').createSync(recursive: true);
      File('$gitDir/mg-watch.lock/token').writeAsStringSync(owner);
      File('$gitDir/mg-watch.tok.hb').writeAsStringSync('');
      final host = _Host();
      final lease = WatchLease(
        executor: host,
        repoPath: root.path,
        gitDir: gitDir,
        token: 'tok',
        timings: WatchTimings.standard,
      );
      await lease.releaseHostClaims();
      final issued = host.argv.single;
      final result = await Process.run(issued.first, issued.sublist(1));
      // Only an owned lock is removed, and the guard `[ token = ours ] && rm`
      // is false otherwise — so a stolen lock exits 1 by design, and the lease
      // ignores the status. Whatever the owner, the command must not have
      // failed for any other reason.
      expect(
        result.stderr,
        isEmpty,
        reason: 'the release command itself must run cleanly',
      );
      if (owner == 'tok') {
        expect(result.exitCode, 0, reason: 'an owned lock is released');
      }
    }

    await releaseWithLockOwnedBy('tok');
    expect(
      File('$gitDir/mg-watch.tok.hb').existsSync(),
      isFalse,
      reason: 'the client removes the lease it wrote',
    );
    expect(
      Directory('$gitDir/mg-watch.lock').existsSync(),
      isFalse,
      reason: 'and gives back the lock it owns',
    );

    await releaseWithLockOwnedBy('someone-else');
    expect(
      File('$gitDir/mg-watch.tok.hb').existsSync(),
      isFalse,
      reason: 'the lease is this client\'s, whoever holds the lock',
    );
    expect(
      Directory('$gitDir/mg-watch.lock').existsSync(),
      isTrue,
      reason:
          'the lock is removed only while this token still owns it, so a '
          'steal in between is never undone',
    );

    await expectLater(
      _lease(_Host(unreachable: true)).releaseHostClaims(),
      completes,
      reason:
          'a teardown during a disconnect has no executor to talk to and must '
          'not fail for it',
    );
  });
}
