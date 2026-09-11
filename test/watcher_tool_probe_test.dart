// MADR 0045 phase 3. Which watcher tool the host has, asked once per watcher's
// life — the probe the arm closure used to carry inline.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/watcher_tool_probe.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Answers the probe with the next scripted result, counting the probes.
class _Probed extends SSHCommandExecutor {
  _Probed(this.results) : super(SSHClientManager());

  final List<SSHCommandResult> results;
  var probes = 0;

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
  }) async =>
      results[probes++ < results.length ? probes - 1 : results.length - 1];
}

const _inotify = SSHCommandResult(
  exitCode: 0,
  stdout: 'inotifywait\n',
  stderr: '',
);

void main() {
  test('the tool is probed once', () async {
    final exec = _Probed([_inotify]);
    final probe = WatcherToolProbe(exec);

    expect(await probe.tool('/repo'), RemoteWatcherTool.inotifywait);
    expect(await probe.tool('/repo'), RemoteWatcherTool.inotifywait);

    expect(
      exec.probes,
      1,
      reason: 'the answer cannot change between one blip\'s retries',
    );
  });

  test('invalidate probes again', () async {
    final exec = _Probed([
      _inotify,
      const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: ''),
    ]);
    final probe = WatcherToolProbe(exec);

    await probe.tool('/repo');
    probe.invalidate();

    expect(
      await probe.tool('/repo'),
      RemoteWatcherTool.fswatch,
      reason: 'recovering from polling is worth asking the host again',
    );
    expect(exec.probes, 2);
  });

  test('a failed probe throws rather than caching none', () async {
    final exec = _Probed([
      const SSHCommandResult(exitCode: 255, stdout: '', stderr: 'broken pipe'),
      _inotify,
    ]);
    final probe = WatcherToolProbe(exec);

    await expectLater(probe.tool('/repo'), throwsA(isA<StateError>()));
    expect(
      await probe.tool('/repo'),
      RemoteWatcherTool.inotifywait,
      reason:
          'a failed command is not evidence about the host\'s tooling; caching '
          '`none` bought three minutes of polling on a host with a good tool '
          '(0024 M3)',
    );
  });
}
