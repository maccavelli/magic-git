import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A [LocalCommandExecutor] that returns canned probe output and records
/// environment-configuration calls — the regression guard for Bug #4
/// (LocalEnvironmentGuard._probe must call setForgeTokenNeutralization).
class _RecordingLocalExecutor extends LocalCommandExecutor {
  final neutralizeCalls = <List<String>>[];
  bool configureEnvironmentCalled = false;
  bool executeCalled = false;

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
  }) async {
    executeCalled = true;
    return const SSHCommandResult(
      exitCode: 0,
      stdout: 'OS=Darwin\nPATH=/usr/local/bin\n',
      stderr: '',
    );
  }

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {
    neutralizeCalls.add(List.of(vars));
    super.setForgeTokenNeutralization(vars);
  }

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {
    configureEnvironmentCalled = true;
    super.configureEnvironment(path: path, binaries: binaries);
  }
}

void main() {
  group('LocalEnvironmentGuard', () {
    test(
        'ensure() runs a probe that configures the executor and calls '
        'setForgeTokenNeutralization', () async {
      final fakeExecutor = _RecordingLocalExecutor();
      final container = ProviderContainer(
        overrides: [
          localExecutorProvider.overrideWithValue(fakeExecutor),
          appSettingsProvider.overrideWith(
            () => AppSettingsNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final guard = container.read(localEnvironmentProvider);
      await guard.ensure();

      // The probe must have run its three-step sequence:
      // 1. execute (resolve environment)
      expect(fakeExecutor.executeCalled, isTrue);
      // 2. configureEnvironment (set resolved PATH / binaries)
      expect(fakeExecutor.configureEnvironmentCalled, isTrue);
      // 3. setForgeTokenNeutralization (mirrors ConnectionController.
      //    _resolveEnvironment — Bug #4 regression guard: this call was
      //    missing before the fix, so a bare local executor would never
      //    neutralize ambient forge-token env vars).
      expect(fakeExecutor.neutralizeCalls, hasLength(1));
    });

    test('ensure() is idempotent when the executor is already configured',
        () async {
      final fakeExecutor = _RecordingLocalExecutor();
      final container = ProviderContainer(
        overrides: [
          localExecutorProvider.overrideWithValue(fakeExecutor),
          appSettingsProvider.overrideWith(
            () => AppSettingsNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final guard = container.read(localEnvironmentProvider);
      await guard.ensure();
      expect(fakeExecutor.neutralizeCalls, hasLength(1));

      final executeCount = fakeExecutor.executeCalled;
      final configCount = fakeExecutor.configureEnvironmentCalled;
      final neutralizeCount = fakeExecutor.neutralizeCalls.length;

      await guard.ensure();

      // Second call must not re-probe.
      expect(fakeExecutor.executeCalled, executeCount);
      expect(fakeExecutor.configureEnvironmentCalled, configCount);
      expect(fakeExecutor.neutralizeCalls, hasLength(neutralizeCount));
    });
  });
}
