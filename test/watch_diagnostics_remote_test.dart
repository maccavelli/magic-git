// 0026 deviation (c), the SSH half. The transition log must be fed by BOTH
// watch services; `watch_diagnostics_local_test.dart` holds the local half,
// which stays on real time because it arms a real `Directory.watch` (MADR 0045
// plan, deviation (r)).
//
// It was wired into RemoteWatchService only, so repos on this Mac produced no
// watcher lines and no transition records — while driving the same lifecycle
// engine, with the same restart budget and the same degrade-to-polling. The
// diagnostic that exposed the lease-ordering bug on the remote host would not
// have appeared for a local repo at all.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_arm_settle.dart';
import 'helpers/fake_watcher_handle.dart';

class _ArmsAlways extends SSHCommandExecutor {
  _ArmsAlways() : super(SSHClientManager());
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
      const SSHCommandResult(exitCode: 0, stdout: 'inotifywait\n', stderr: '');

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => FakeWatcherHandle.armed();
}

void main() {
  late HostWatcherBudget hostBudget;

  setUp(() {
    watchDiagnostics.clear();
    hostBudget = HostWatcherBudget();
  });
  tearDown(watchDiagnostics.clear);

  test('the SSH backend records its watch transitions', () {
    fakeAsync((async) {
      final sub = RemoteWatchService(
        _ArmsAlways(),
        admission: WatchAdmission(budget: hostBudget),
        gitDirOf: conventionalGitDir,
      ).watch('/srv/repo').listen((_) {});
      async.letArmsSettle();
      expect(
        watchDiagnostics.forRepo('/srv/repo').records,
        isNotEmpty,
        reason: 'the remote service feeds the transition log',
      );
      sub.cancel();
      async.flushMicrotasks();
    });
  });
}
