// MADR 0030 T2.6. Connect-path contracts, driven at the unit level.
//
// The plan aimed this at `connect()` / `connectLocal()` — 68 uncovered lines.
// Driving those directly is not possible offline: `connectLocal` alone reaches
// `ScopedAccess.instance` (the macOS sandbox singleton), the SSH client
// manager, the binary-environment notifier and four more providers, and a test
// that stubbed all of them would be asserting its own stubs.
//
// So this covers the connect-path CONTRACTS that can be asserted honestly,
// each on the unit that owns it. What is not covered is named at the bottom
// rather than left to look covered.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Fails every command, the way a host that has gone away does.
class _FailingExecutor extends SSHCommandExecutor {
  _FailingExecutor() : super(SSHClientManager());
  int calls = 0;

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
    calls++;
    throw StateError('transport is gone');
  }
}

/// Succeeds, and records which repos it was asked to sweep.
class _RecordingExecutor extends SSHCommandExecutor {
  _RecordingExecutor() : super(SSHClientManager());
  final swept = <String>[];

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
    swept.add(repoPath);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  test('the connect-time sweep runs for every repo it is given', () async {
    final exec = _RecordingExecutor();
    await RemoteWatchService(
      exec,
    ).sweepStaleWatchers({'/srv/a': '/srv/a/.git', '/srv/b': '/srv/b/.git'});
    expect(exec.swept, containsAll(<String>['/srv/a', '/srv/b']));
  });

  test('a sweep failure NEVER fails the connect', () async {
    // `sweepStaleWatchers` is documented best-effort: reclaiming orphans is
    // housekeeping, and a host that refuses it must still yield a usable
    // session. If this ever throws, a stale watcher on an unreachable host
    // becomes a connect failure — trading a background tidy-up for the whole
    // feature.
    final lines = <String>[];
    final exec = _FailingExecutor();

    await expectLater(
      RemoteWatchService(
        exec,
        onDiagnostic: lines.add,
      ).sweepStaleWatchers({'/srv/a': '/srv/a/.git'}),
      completes,
    );

    expect(exec.calls, 1, reason: 'it really did try');
    expect(
      lines.any((l) => l.contains('sweep failed')),
      isTrue,
      reason: 'swallowed, but not silently — the failure reaches the log',
    );
  });

  test('an empty repo set is a no-op, not an error', () async {
    final exec = _RecordingExecutor();
    await RemoteWatchService(exec).sweepStaleWatchers({});
    expect(exec.swept, isEmpty);
  });

  // ---- what this file does NOT cover, and why ---------------------------
  //
  // The plan aimed at 68 uncovered lines in `connect()` / `connectLocal()`.
  // They are still uncovered. Driving either offline is not possible without
  // stubbing `ScopedAccess.instance` (the macOS sandbox singleton), the SSH
  // client manager, the binary-environment notifier, the ping-sample store and
  // the output log — at which point the test asserts the arrangement of its own
  // stubs and not the controller.
  //
  // Specifically NOT asserted here:
  //
  //  * the generation guard (`final attempt = ++_attempt; … if (attempt !=
  //    _attempt) return;`) that stops a superseded connect from marking,
  //    invalidating or logging against the connection that replaced it;
  //  * `connectLocal` establishing a local backend without touching SSH state;
  //  * a forge-auth failure leaving `forgeAuthPending` true rather than
  //    surfacing as a broken working tree.
  //
  // Covering those means a harness that can construct a ConnectionController
  // with every collaborator faked, which is its own piece of work and should be
  // decided as such rather than smuggled into a testing sweep.
}
