// MADR 0041 phase 4. The watcher ceiling is derived from the transport's own
// stream budget, and keyed by HOST.
//
// Both halves matter, and the second is the one with history. MADR 0040's phase
// 2 derived the cap correctly and keyed it per (session, host) — right for the
// resource it derives from, since channels belong to a connection, and wrong
// for the resource watchers also consume. With up to eight tab containers that
// took the host-wide bound from 2 to as much as 48 and left nothing bounding
// the host at all. It was reverted for exactly that (0041 F5).
//
// So the last test here is not a detail. It is the regression guard for the
// decision, and it fails the moment the key grows a session component again.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/watch_settle.dart';

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

/// Arms every time, so each arm holds a slot until it is cancelled.
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

void main() {
  setUp(RemoteWatchService.resetWatcherCount);
  tearDown(() async {
    await settleArm();
    RemoteWatchService.resetWatcherCount();
  });

  RemoteWatchService serviceOn(String host, {required int budget}) =>
      RemoteWatchService(
        _ArmsAlways(),
        hostKey: () => host,
        streamBudget: () => budget,
      );

  test('the cap is the stream budget less the reserved channels', () {
    expect(
      serviceOn('h', budget: 8).maxConcurrentWatchers,
      8 - RemoteWatchService.reservedStreams,
      reason:
          'a healthy triple-client session watches six repositories, where the '
          'constant 2 stood in front of the same 8 and never referred to it',
    );
  });

  test('a degraded budget floors at one, rather than at zero or below', () {
    // 2 - 2 = 0, and a session that watches nothing at all is worse than one
    // that watches the repository the user is looking at.
    expect(serviceOn('h', budget: 2).maxConcurrentWatchers, 1);
    expect(
      serviceOn('h', budget: 1).maxConcurrentWatchers,
      1,
      reason: 'the floor is a floor, not arithmetic that happens to work',
    );
  });

  test('the cap is read per arm, so a budget that drops is honoured', () async {
    var budget = 8;
    final service = RemoteWatchService(
      _ArmsAlways(),
      hostKey: () => 'h',
      streamBudget: () => budget,
    );
    expect(service.maxConcurrentWatchers, 6);

    // The dedicated stream client degrades onto the command client mid-session.
    budget = 2;
    expect(
      service.maxConcurrentWatchers,
      1,
      reason:
          'a value read once at construction would pin the healthy number '
          'through a degradation and keep arming into a budget that is gone',
    );
  });

  test('two sessions on one host share ONE budget', () async {
    // The regression guard for MADR 0041 F5. Each of these stands for a tab
    // container: its own service, its own executor, its own connection — and
    // the same host. If the counter ever grows a session component again, each
    // gets its own ceiling and the host's bound becomes N x the cap.
    final tabOne = serviceOn('same-host', budget: 4); // ceiling 2
    final tabTwo = serviceOn('same-host', budget: 4);

    final a = tabOne.watch('/a').listen((_) {});
    final b = tabOne.watch('/b').listen((_) {});
    await settleArm();
    expect(RemoteWatchService.liveWatchersFor('same-host'), 2);

    final events = <RepoWatchEvent>[];
    final c = tabTwo.watch('/c').listen(events.add);
    await settleArm();

    expect(
      events.last.mode,
      WatchMode.polling,
      reason:
          'the second tab must be refused by the FIRST tab\'s watchers. Keyed '
          'per (session, host) it would be granted, and eight tabs would put '
          'up to 48 watchers on one host with nothing bounding it',
    );
    expect(
      RemoteWatchService.liveWatchersFor('same-host'),
      2,
      reason: 'the host budget is spent, whoever spent it',
    );

    await a.cancel();
    await b.cancel();
    await c.cancel();
  });

  test('two hosts do not share a budget', () async {
    // The other half of the same decision (MADR 0039 F4): keyed by host means
    // a host that has consumed nothing is not starved by one that has.
    final alpha = serviceOn('alpha', budget: 4);
    final beta = serviceOn('beta', budget: 4);

    final a1 = alpha.watch('/a1').listen((_) {});
    final a2 = alpha.watch('/a2').listen((_) {});
    await settleArm();
    expect(RemoteWatchService.liveWatchersFor('alpha'), 2);

    final events = <RepoWatchEvent>[];
    final b1 = beta.watch('/b1').listen(events.add);
    await settleArm();

    expect(
      events.last.mode,
      WatchMode.eventDriven,
      reason: 'beta has spent nothing and must not be refused',
    );
    expect(RemoteWatchService.liveWatchersFor('beta'), 1);

    await a1.cancel();
    await a2.cancel();
    await b1.cancel();
  });

  test('an unwired service is conservative, not optimistic', () {
    // A caller that forgets `streamBudget` gets the degraded figure, so the
    // failure mode of the wiring going missing is one watcher too few rather
    // than a host with no bound.
    expect(
      RemoteWatchService(_ArmsAlways()).maxConcurrentWatchers,
      1,
      reason: 'the default assumes the degraded single-client budget',
    );
  });
}
