// MADR 0045 phase 2. Sharing one watcher between listeners is Riverpod's.
//
// These are the three sharing tests `watch_shared_path_test.dart` held against
// `_SharedWatch`, moved to the layer that now owns the guarantee, plus the two
// lifetime cases that make "one provider instance per repository per container"
// a statement about watchers. `repoWatchProvider` is the only production caller
// of the watch services, so what a listener sees here is what the app sees.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_arm_settle.dart';
import 'helpers/fake_watcher_handle.dart';

const _repo = '/repo';

/// Records every arm, so "how many watchers exist" is a number.
class _ArmRecorder extends SSHCommandExecutor {
  _ArmRecorder() : super(SSHClientManager());

  final handles = <FakeWatcherHandle>[];

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
  }) async {
    final handle = FakeWatcherHandle.armed();
    handles.add(handle);
    return handle;
  }
}

/// A connection that is simply there: SSH, no scoped git-dir.
class _Idle extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState();
}

void main() {
  late HostWatcherBudget budget;
  late _ArmRecorder exec;
  late ProviderContainer container;

  setUp(() {
    budget = HostWatcherBudget();
    exec = _ArmRecorder();
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionProvider.overrideWith(_Idle.new),
        remoteWatchServiceProvider.overrideWithValue(
          RemoteWatchService(
            exec,
            hostKey: () => 'host',
            streamBudget: () => 8,
            admission: WatchAdmission(budget: budget),
            gitDirOf: conventionalGitDir,
          ),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    watchDiagnostics.clear();
  });

  /// Modes one listener has seen.
  ProviderSubscription<AsyncValue<RepoWatchEvent>> listen(
    List<WatchMode> into, {
    bool fireImmediately = false,
  }) => container.listen<AsyncValue<RepoWatchEvent>>(repoWatchProvider(_repo), (
    _,
    next,
  ) {
    final mode = next.value?.mode;
    if (mode != null) into.add(mode);
  }, fireImmediately: fireImmediately);

  test('two listeners on one repository arm one watcher', () {
    fakeAsync((async) {
      final a = listen([]);
      final b = listen([]);
      async.letArmsSettle();

      expect(
        exec.handles,
        hasLength(1),
        reason:
            'one provider instance per repository per container, so one watcher '
            '— the guarantee `_SharedWatch` used to rebuild by hand',
      );
      expect(budget.liveFor('host'), 1);

      a.close();
      b.close();
    });
  });

  test('both listeners receive the same events', () {
    fakeAsync((async) {
      final seenA = <WatchMode>[];
      final seenB = <WatchMode>[];
      final a = listen(seenA);
      final b = listen(seenB);
      async.letArmsSettle();

      expect(seenA, isNotEmpty, reason: 'the first listener sees the arm');
      expect(
        seenB,
        equals(seenA),
        reason: 'sharing a watcher means sharing its events, not just its cost',
      );

      a.close();
      b.close();
    });
  });

  test('a late listener gets the current mode immediately', () {
    fakeAsync((async) {
      final a = listen([]);
      async.letArmsSettle();

      // Attaching to an already-armed, quiet repository. Without the provider's
      // current value this listener would have no mode until something happened
      // on the host — which on a quiet repository can be a long time.
      final late = <WatchMode>[];
      final b = listen(late, fireImmediately: true);

      expect(late, [
        WatchMode.eventDriven,
      ], reason: 'the current value is delivered on attach, without waiting');
      expect(exec.handles, hasLength(1), reason: 'and still only one watcher');

      a.close();
      b.close();
    });
  });

  test('one listener leaving keeps the watcher', () {
    fakeAsync((async) {
      final a = listen([]);
      final b = listen([]);
      async.letArmsSettle();

      a.close();
      async.letArmsSettle();

      expect(
        exec.handles.single.cancelled,
        isFalse,
        reason:
            'tearing down while another listener is still watching would take '
            'the watcher away from someone who never asked for that',
      );
      expect(budget.liveFor('host'), 1);

      b.close();
    });
  });

  test('the last listener leaving tears the watcher down', () {
    fakeAsync((async) {
      final a = listen([]);
      final b = listen([]);
      async.letArmsSettle();

      a.close();
      b.close();
      async.letArmsSettle();

      expect(
        exec.handles.single.cancelled,
        isTrue,
        reason: 'nobody is listening, so the host must not keep a watcher',
      );
      expect(budget.liveFor('host'), 0, reason: 'and the slot goes back');
    });
  });

  test('a returning listener on a quiet repository gets a watcher at once', () {
    fakeAsync((async) {
      // MADR 0045 amendment 0045.1. The ignored-path filter used to be an
      // `async*` generator, which observes a cancel only at its next yield: a
      // quiet repository's watcher outlived its last listener, and a view coming
      // back waited on that watcher's lock instead of getting one of its own.
      final first = listen([]);
      async.letArmsSettle();
      first.close();
      // `container.pump()`: the scheduler disposes on a zero-duration timer.
      async.elapse(Duration.zero);
      async.letArmsSettle();

      expect(
        exec.handles.single.cancelled,
        isTrue,
        reason: 'leaving reaches a watcher that has had nothing to report',
      );

      final back = <WatchMode>[];
      final returned = listen(back, fireImmediately: true);
      async.letArmsSettle();

      expect(
        back,
        contains(WatchMode.eventDriven),
        reason:
            'the returning view is watching, not waiting on a watcher nobody holds',
      );
      expect(exec.handles, hasLength(2));
      expect(exec.handles.last.cancelled, isFalse);

      returned.close();
    });
  });
}
