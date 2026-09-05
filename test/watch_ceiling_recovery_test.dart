// MADR 0028 H2. A repo refused by the watcher ceiling must arm as soon as a
// slot frees, not wait out a 3-minute recovery timer.
//
// The ceiling is a property of THIS process, not of the host: it resolves the
// instant another watcher stops, and `releaseSlot()` already knows that moment.
// Until now nothing listened, so a third watched repo polled at 48 host
// processes per minute for up to three minutes after room appeared — and
// indefinitely if the slots stayed occupied, which is the steady state.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
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

/// Reports a watcher tool and arms successfully, so every arm holds a slot.
class _ArmsAlways extends SSHCommandExecutor {
  _ArmsAlways({this.tool = 'inotifywait'}) : super(SSHClientManager());
  final String tool;

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
  }) async => SSHCommandResult(exitCode: 0, stdout: '$tool\n', stderr: '');

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
  tearDown(RemoteWatchService.resetWatcherCount);

  test('a repo refused by the ceiling arms as soon as a slot frees', () async {
    final service = RemoteWatchService(_ArmsAlways());
    final events = <RepoWatchEvent>[];

    final a = service.watch('/a').listen((_) {});
    final b = service.watch('/b').listen((_) {});
    await pumpEventQueue();
    expect(
      RemoteWatchService.liveWatchers,
      RemoteWatchService.maxConcurrentWatchers,
      reason: 'the ceiling is full',
    );

    final c = service.watch('/c').listen(events.add);
    await pumpEventQueue();
    expect(
      events.last.mode,
      WatchMode.polling,
      reason: 'refused by the ceiling, so it polls',
    );

    // Room appears. No time is advanced: the recovery timer is three minutes
    // away, so anything that happens now happened because of the release.
    await a.cancel();
    await pumpEventQueue();

    expect(
      events.last.mode,
      WatchMode.eventDriven,
      reason: 'a freed slot must be taken immediately, not in three minutes',
    );

    await b.cancel();
    await c.cancel();
  });

  test(
    'two service instances share one ceiling, they do not each get one',
    () async {
      // 0028 deviation (a). `_liveWatchers` is static because several providers
      // construct their own RemoteWatchService against the same host, and the
      // budget belongs to the host, not to a service object. Counting per
      // instance would hand each one its own two slots and multiply the ceiling
      // — the opposite of enforcing it.
      //
      // This also pins the assumption the "one connection may hold" wording
      // rests on: the app holds ONE connection at a time, so process-global and
      // per-connection are the same set. If simultaneous connections to
      // different hosts ever land, this test is where that stops being true and
      // the counter needs keying by host.
      final first = RemoteWatchService(_ArmsAlways());
      final second = RemoteWatchService(_ArmsAlways());

      final a = first.watch('/a').listen((_) {});
      final b = second.watch('/b').listen((_) {});
      await pumpEventQueue();
      expect(
        RemoteWatchService.liveWatchers,
        2,
        reason: 'one budget across both services, not two budgets of two',
      );

      final events = <RepoWatchEvent>[];
      final c = second.watch('/c').listen(events.add);
      await pumpEventQueue();
      expect(
        events.last.mode,
        WatchMode.polling,
        reason: 'the ceiling binds across service instances',
      );

      await a.cancel();
      await b.cancel();
      await c.cancel();
    },
  );

  test(
    'a refusal that is NOT the ceiling is not woken by a slot release',
    () async {
      // `noTool` means the host has no inotifywait/fswatch. A freed watcher slot
      // changes nothing about that, and re-probing on every release would spend
      // round trips discovering the same answer.
      final service = RemoteWatchService(_ArmsAlways(tool: ''));
      final events = <RepoWatchEvent>[];
      final held = RemoteWatchService(_ArmsAlways());

      final x = held.watch('/x').listen((_) {});
      await pumpEventQueue();

      final n = service.watch('/notool').listen(events.add);
      await pumpEventQueue();
      expect(events.last.mode, WatchMode.polling);
      final armsBefore = events.length;

      await x.cancel();
      await pumpEventQueue();

      expect(
        events.last.mode,
        WatchMode.polling,
        reason: 'a slot release must not re-probe a host that has no tool',
      );
      expect(events.length, armsBefore, reason: 'no new tick was emitted');
      await n.cancel();
    },
  );
}
