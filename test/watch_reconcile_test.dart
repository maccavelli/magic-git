// MADR 0040, phase 3. The slot count reconciles against the host at connect, so
// bookkeeping that goes wrong for a reason nobody anticipated heals by itself
// instead of costing the session a slot until it is restarted.
//
// Phase 1 made the release structural, so a leak should be impossible. This is
// the belt to that braces — and the reason it is worth having is that the cap is
// small: one stranded slot used to be a permanent halving of a host's capacity.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
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

/// Arms successfully, and answers the sweep with whatever [sweepStdout] says.
class _Exec extends SSHCommandExecutor {
  _Exec({this.sweepStdout = '', this.sweepThrows = false})
    : super(SSHClientManager());

  final String sweepStdout;
  final bool sweepThrows;

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
    final joined = gitArgs.join(' ');
    if (joined.contains('mg-watch')) {
      if (sweepThrows) throw StateError('sweep exploded');
      return SSHCommandResult(exitCode: 0, stdout: sweepStdout, stderr: '');
    }
    return const SSHCommandResult(
      exitCode: 0,
      stdout: 'inotifywait\n',
      stderr: '',
    );
  }

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

int _budgetFor2() => RemoteWatchService.reservedStreams + 2;

void main() {
  setUp(RemoteWatchService.resetWatcherCount);
  tearDown(RemoteWatchService.resetWatcherCount);

  group('the sweep report', () {
    // The script's OUTPUT is asserted by executing it, in
    // `watcher_sweep_exec_test.dart` — a `contains(...)` on generated shell text
    // cannot see a script that prints the wrong thing (MADR 0029). What is
    // asserted here is the Dart half: how that output is read.

    test('parsing takes LIVE lines and ignores everything else', () {
      expect(
        RemoteWatchService.parseSweptLiveTokens(
          'LIVE abc123\n'
          'some unrelated stderr-ish line\n'
          'LIVE def456\n'
          'LIVE \n' // the legacy tokenless heartbeat strips to empty
          '\n',
        ),
        {'abc123', 'def456'},
      );
    });
  });

  group('reconciliation', () {
    test('a slot the host no longer holds is reclaimed', () async {
      // Arm one watcher, then sweep with a report that does NOT mention it —
      // which is what a stranded slot looks like from the host's side.
      final service = RemoteWatchService(
        _Exec(sweepStdout: 'LIVE someone-elses-token\n'),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-a',
      );
      final sub = service.watch('/repo').listen((_) {});
      await pumpEventQueue();
      expect(RemoteWatchService.liveWatchersIn('tab-a', 'bastion'), 1);

      await service.sweepStaleWatchers({'/repo': '/repo/.git'});

      expect(
        RemoteWatchService.liveWatchersIn('tab-a', 'bastion'),
        0,
        reason: 'the host does not report this token, so the slot is not real',
      );
      await sub.cancel();
    });

    test('a slot the host DOES hold is left alone', () async {
      // The guard against a reconciliation that "fixes" a correct count by
      // zeroing it — which would release a slot out from under a live watcher.
      late String token;
      final service = RemoteWatchService(
        _Exec(),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-a',
      );
      final sub = service.watch('/repo').listen((_) {});
      await pumpEventQueue();
      expect(RemoteWatchService.liveWatchersIn('tab-a', 'bastion'), 1);

      // Report exactly the token the service is holding.
      token = RemoteWatchService.heldTokens('tab-a', 'bastion').single;
      final live = RemoteWatchService(
        _Exec(sweepStdout: 'LIVE $token\n'),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-a',
      );
      await live.sweepStaleWatchers({'/repo': '/repo/.git'});

      expect(
        RemoteWatchService.liveWatchersIn('tab-a', 'bastion'),
        1,
        reason: 'a live watcher must keep its slot',
      );
      await sub.cancel();
    });

    test('a failed sweep leaves the count untouched', () async {
      // Best-effort by design. A sweep that cannot run tells us nothing about
      // the host, and treating "no answer" as "nothing is live" would release
      // every slot on a transport blip.
      final service = RemoteWatchService(
        _Exec(),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-a',
      );
      final sub = service.watch('/repo').listen((_) {});
      await pumpEventQueue();

      final failing = RemoteWatchService(
        _Exec(sweepThrows: true),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-a',
      );
      await failing.sweepStaleWatchers({'/repo': '/repo/.git'});

      expect(RemoteWatchService.liveWatchersIn('tab-a', 'bastion'), 1);
      await sub.cancel();
    });

    test('a sweep never throws out of the connect path', () async {
      final failing = RemoteWatchService(
        _Exec(sweepThrows: true),
        hostKey: () => 'bastion',
        scope: 'tab-a',
      );
      await expectLater(
        failing.sweepStaleWatchers({'/repo': '/repo/.git'}),
        completes,
      );
    });

    test('one session does not reconcile another session away', () async {
      final tabA = RemoteWatchService(
        _Exec(),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-a',
      );
      final tabB = RemoteWatchService(
        _Exec(sweepStdout: 'LIVE nothing-of-tab-as\n'),
        hostKey: () => 'bastion',
        streamBudget: _budgetFor2,
        scope: 'tab-b',
      );
      final a = tabA.watch('/repo-a').listen((_) {});
      final b = tabB.watch('/repo-b').listen((_) {});
      await pumpEventQueue();
      expect(RemoteWatchService.liveWatchersIn('tab-a', 'bastion'), 1);
      expect(RemoteWatchService.liveWatchersIn('tab-b', 'bastion'), 1);

      // Tab B sweeps and sees none of ITS tokens; tab A's are none of its
      // business and must survive.
      await tabB.sweepStaleWatchers({'/repo-b': '/repo-b/.git'});

      expect(
        RemoteWatchService.liveWatchersIn('tab-a', 'bastion'),
        1,
        reason:
            'another tab\'s watchers are live and not this sweep\'s to drop',
      );
      expect(RemoteWatchService.liveWatchersIn('tab-b', 'bastion'), 0);

      await a.cancel();
      await b.cancel();
    });
  });
}
