// localEnvironmentProvider: the on-demand environment probe for This-Mac
// work that runs outside any local session (landing create/clone sheets,
// This-Mac forge browse). Without it, a GUI-launched app's bare inherited
// PATH hides Homebrew-installed gh/glab and forge commands exit 127.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProbeExecutor extends LocalCommandExecutor {
  int executions = 0;

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
  }) async {
    executions++;
    return const SSHCommandResult(
      exitCode: 0,
      stdout:
          'OS=Darwin\n'
          'PATH=/opt/homebrew/bin:/usr/bin:/bin\n'
          'BIN=git=/opt/homebrew/bin/git\n'
          'BIN=gh=/opt/homebrew/bin/gh\n',
      stderr: '',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probes and configures an unconfigured local executor once', () async {
    SharedPreferences.setMockInitialValues({});
    final exec = _ProbeExecutor();
    final container = ProviderContainer(
      overrides: [localExecutorProvider.overrideWithValue(exec)],
    );
    addTearDown(container.dispose);

    expect(exec.isConfigured, isFalse);
    await container.read(localEnvironmentProvider).ensure();
    expect(exec.isConfigured, isTrue, reason: 'PATH/binaries applied');
    expect(exec.executions, 1);

    // Already configured — the guard makes the next call a no-op instead
    // of a second probe.
    await container.read(localEnvironmentProvider).ensure();
    expect(exec.executions, 1);
  });

  test('a reset executor is re-probed on the next read', () async {
    SharedPreferences.setMockInitialValues({});
    final exec = _ProbeExecutor();
    final container = ProviderContainer(
      overrides: [localExecutorProvider.overrideWithValue(exec)],
    );
    addTearDown(container.dispose);

    await container.read(localEnvironmentProvider).ensure();
    expect(exec.executions, 1);

    exec.resetEnvironment(); // e.g. a session teardown
    expect(exec.isConfigured, isFalse);

    await container.read(localEnvironmentProvider).ensure();
    expect(exec.executions, 2, reason: 'stale reset state is not cached');
    expect(exec.isConfigured, isTrue);
  });
}
