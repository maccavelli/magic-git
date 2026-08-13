import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
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
    test('ensure() runs a probe that configures the executor and calls '
        'setForgeTokenNeutralization', () async {
      final fakeExecutor = _RecordingLocalExecutor();
      final container = ProviderContainer(
        overrides: [
          localExecutorProvider.overrideWithValue(fakeExecutor),
          appSettingsProvider.overrideWith(() => AppSettingsNotifier()),
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

    test(
      'ensure() is idempotent when the executor is already configured',
      () async {
        final fakeExecutor = _RecordingLocalExecutor();
        final container = ProviderContainer(
          overrides: [
            localExecutorProvider.overrideWithValue(fakeExecutor),
            appSettingsProvider.overrideWith(() => AppSettingsNotifier()),
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
      },
    );
  });

  group('WindowBoundsStore', () {
    test('load returns null on first launch (no stored values)', () async {
      SharedPreferences.setMockInitialValues({});
      final result = await WindowBoundsStore.load();
      expect(result, isNull);
    });

    test('load returns stored bounds when valid', () async {
      SharedPreferences.setMockInitialValues({
        'windowBoundsX': 100.0,
        'windowBoundsY': 50.0,
        'windowBoundsWidth': 1200.0,
        'windowBoundsHeight': 800.0,
      });
      final result = await WindowBoundsStore.load();
      expect(result, isNotNull);
      final (x, y, w, h) = result!;
      expect(x, 100.0);
      expect(y, 50.0);
      expect(w, 1200.0);
      expect(h, 800.0);
    });

    test('load returns null when width is below minimum', () async {
      SharedPreferences.setMockInitialValues({
        'windowBoundsX': 0.0,
        'windowBoundsY': 0.0,
        'windowBoundsWidth': 100.0,
        'windowBoundsHeight': 800.0,
      });
      final result = await WindowBoundsStore.load();
      expect(result, isNull);
    });

    test('load returns null when height is below minimum', () async {
      SharedPreferences.setMockInitialValues({
        'windowBoundsX': 0.0,
        'windowBoundsY': 0.0,
        'windowBoundsWidth': 1200.0,
        'windowBoundsHeight': 50.0,
      });
      final result = await WindowBoundsStore.load();
      expect(result, isNull);
    });

    test('load returns null on storage error', () async {
      // SharedPreferences.getInstance throws when no mock is set
      final result = await WindowBoundsStore.load();
      expect(result, isNull);
    });

    test('save persists bounds that load can retrieve', () async {
      SharedPreferences.setMockInitialValues({});
      await WindowBoundsStore.save(200.0, 300.0, 1440.0, 900.0);
      final result = await WindowBoundsStore.load();
      expect(result, isNotNull);
      final (x, y, w, h) = result!;
      expect(x, 200.0);
      expect(y, 300.0);
      expect(w, 1440.0);
      expect(h, 900.0);
    });

    test('save does not throw when storage is unavailable', () async {
      await WindowBoundsStore.save(0, 0, 640, 480);
      // No exception means the silent catch worked.
    });
  });

  group('OwnMutationTracker', () {
    test('mark records the repo path', () {
      final tracker = OwnMutationTracker();
      tracker.mark('path/a');
      expect(
        tracker.isRecent('path/a', DateTime.now(), const Duration(seconds: 5)),
        isTrue,
      );
    });

    test('isRecent returns false for unknown repo', () {
      final tracker = OwnMutationTracker();
      expect(
        tracker.isRecent(
          'never-marked',
          DateTime.now(),
          const Duration(seconds: 5),
        ),
        isFalse,
      );
    });

    test('isRecent returns false when outside the time window', () {
      final tracker = OwnMutationTracker();
      tracker.mark('path/b');
      final later = DateTime.now().add(const Duration(milliseconds: 2));
      expect(
        tracker.isRecent('path/b', later, const Duration(milliseconds: 1)),
        isFalse,
      );
    });

    test('isRecent respects the within duration', () {
      final tracker = OwnMutationTracker();
      tracker.mark('path/c');
      final slightlyLater = DateTime.now().add(const Duration(milliseconds: 1));
      expect(
        tracker.isRecent(
          'path/c',
          slightlyLater,
          const Duration(milliseconds: 5),
        ),
        isTrue,
      );
    });

    test('clear removes all entries', () {
      final tracker = OwnMutationTracker();
      tracker.mark('path/d');
      tracker.mark('path/e');
      tracker.clear();
      expect(
        tracker.isRecent('path/d', DateTime.now(), const Duration(seconds: 5)),
        isFalse,
      );
      expect(
        tracker.isRecent('path/e', DateTime.now(), const Duration(seconds: 5)),
        isFalse,
      );
    });
  });
}
