// MADR 0040 F3/F4. The watcher cap is derived from the transport's own ceiling
// on long-lived stream channels, not chosen in isolation.
//
// It used to be the constant 2, standing in front of a `maxConcurrentStreams`
// of 8 that is already enforced at `executeStream` and already degrades
// gracefully. Nothing connected the two numbers, and on a fifteen-repository
// host that cap forced thirteen repositories onto a poll measured at ~48 git
// processes per minute each, while the host used 0.18 % of its inotify budget.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _Handle implements SSHStreamHandle {
  final _out = StreamController<String>.broadcast();
  final _err = StreamController<String>.broadcast();
  @override
  Stream<String> get stdout => _out.stream;
  @override
  Stream<String> get stderr => _err.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    await _out.close();
    await _err.close();
  }
}

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
  }) async => _Handle();
}

/// Ceiling refusals recorded for one repo. A session woken by a release it
/// cannot use runs an arm that can only lose, and files one of these.
int _ceilingRefusals(String repoPath) => watchDiagnostics
    .forRepo(repoPath)
    .records
    .where(
      (r) =>
          r.kind == WatchTransition.armFailed && r.cause.startsWith('ceiling'),
    )
    .length;

void main() {
  setUp(() {
    RemoteWatchService.resetWatcherCount();
    watchDiagnostics.clear();
  });
  tearDown(RemoteWatchService.resetWatcherCount);

  group('derivation', () {
    test('a healthy triple client yields budget minus reserved channels', () {
      // 8 streams, 2 held back for the CI job trace and clone progress.
      final service = RemoteWatchService(_ArmsAlways(), streamBudget: () => 8);
      expect(
        service.maxConcurrentWatchers,
        8 - RemoteWatchService.reservedStreams,
      );
      expect(RemoteWatchService.reservedStreams, 2);
    });

    test('a degraded client floors at one, never zero', () {
      // Degraded onto the command client the budget is 2, and 2 - 2 = 0. A cap
      // of 0 would silently disable watching for the whole session — every repo
      // polling with a "ceiling 0/0" nobody could act on.
      final service = RemoteWatchService(_ArmsAlways(), streamBudget: () => 2);
      expect(service.maxConcurrentWatchers, 1);
    });

    test('an unwired service is conservative, not optimistic', () {
      // The default exists for callers that forget. It must not hand out more
      // than a degraded connection could carry.
      expect(RemoteWatchService(_ArmsAlways()).maxConcurrentWatchers, 1);
    });

    test('the cap follows the budget when it changes mid-session', () {
      // Why it is a callback and not a value: the dedicated stream client can
      // degrade onto the command client and be re-dialled later, and reading the
      // budget once would pin whichever answer happened to be true at
      // construction.
      var budget = 8;
      final service = RemoteWatchService(
        _ArmsAlways(),
        streamBudget: () => budget,
      );
      expect(service.maxConcurrentWatchers, 6);
      budget = 2; // the stream client dropped
      expect(service.maxConcurrentWatchers, 1);
      budget = 8; // the redial landed
      expect(service.maxConcurrentWatchers, 6);
    });
  });

  group('per session and host', () {
    test('two sessions on one host each get their own budget', () {
      // The behaviour change. Three tabs on one bastion used to share two
      // watchers between them; the channel budget they are derived from is per
      // connection, and each tab has its own.
      final tabA = RemoteWatchService(
        _ArmsAlways(),
        hostKey: () => 'bastion',
        streamBudget: () => 3, // cap 1
        scope: 'tab-a',
      );
      final tabB = RemoteWatchService(
        _ArmsAlways(),
        hostKey: () => 'bastion',
        streamBudget: () => 3, // cap 1
        scope: 'tab-b',
      );

      final events = <RepoWatchEvent>[];
      final a = tabA.watch('/one').listen((_) {});
      final b = tabB.watch('/one').listen(events.add);

      return pumpEventQueue().then((_) async {
        expect(RemoteWatchService.liveWatchersIn('tab-a', 'bastion'), 1);
        expect(
          RemoteWatchService.liveWatchersIn('tab-b', 'bastion'),
          1,
          reason: 'tab B has its own connection and its own channel budget',
        );
        expect(events.last.mode, WatchMode.eventDriven);
        expect(RemoteWatchService.liveWatchersFor('bastion'), 2);
        await a.cancel();
        await b.cancel();
      });
    });

    test('one session still cannot exceed its own cap', () async {
      final tab = RemoteWatchService(
        _ArmsAlways(),
        hostKey: () => 'bastion',
        streamBudget: () => 3, // cap 1
        scope: 'tab-a',
      );

      final first = tab.watch('/one').listen((_) {});
      await pumpEventQueue();
      final refused = <RepoWatchEvent>[];
      final second = tab.watch('/two').listen(refused.add);
      await pumpEventQueue();

      expect(refused.last.mode, WatchMode.polling);
      expect(RemoteWatchService.liveWatchersIn('tab-a', 'bastion'), 1);

      await first.cancel();
      await second.cancel();
    });

    test('a freed slot wakes only the session that can use it', () async {
      // The release announcement is keyed the same way the reservation is, so a
      // slot freed in one tab does not wake a repo waiting in another tab that
      // is still at its own cap.
      final tabA = RemoteWatchService(
        _ArmsAlways(),
        hostKey: () => 'bastion',
        streamBudget: () => 3,
        scope: 'tab-a',
      );
      final tabB = RemoteWatchService(
        _ArmsAlways(),
        hostKey: () => 'bastion',
        streamBudget: () => 3,
        scope: 'tab-b',
      );

      // Distinct paths per tab: `watchDiagnostics` is keyed by repo path alone,
      // so two tabs watching the same path would file into one log.
      final aHeld = tabA.watch('/a-one').listen((_) {});
      final bHeld = tabB.watch('/b-one').listen((_) {});
      await pumpEventQueue();

      final aWaiting = <RepoWatchEvent>[];
      final bWaiting = <RepoWatchEvent>[];
      final aQueued = tabA.watch('/a-two').listen(aWaiting.add);
      final bQueued = tabB.watch('/b-two').listen(bWaiting.add);
      await pumpEventQueue();
      expect(aWaiting.last.mode, WatchMode.polling);
      expect(bWaiting.last.mode, WatchMode.polling);

      final aRefusalsBefore = _ceilingRefusals('/a-two');
      expect(aRefusalsBefore, greaterThan(0));

      await bHeld.cancel(); // frees tab B's only slot
      await pumpEventQueue();

      expect(
        bWaiting.last.mode,
        WatchMode.eventDriven,
        reason: 'tab B freed its own slot and its waiting repo takes it',
      );
      expect(
        aWaiting.last.mode,
        WatchMode.polling,
        reason: 'tab A is still at its cap',
      );
      // The mode is polling either way — a woken session at its cap is simply
      // refused again — so the mode cannot see this. The wasted arm can.
      expect(
        _ceilingRefusals('/a-two'),
        aRefusalsBefore,
        reason:
            'a slot freed in another session must not wake this one into an '
            'arm it can only lose',
      );

      await aHeld.cancel();
      await aQueued.cancel();
      await bQueued.cancel();
    });
  });
}
