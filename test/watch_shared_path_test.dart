// MADR 0043. One watcher per repository path, however many callers ask.
//
// Arming twice was possible, and the second arm was refused by this app's OWN
// host-side lock: a healthy repository degraded to polling for three minutes
// because it collided with itself, and said "another live watcher already
// holds" while there was no other session (0043 F1). `heldByAnother` is only
// worth trusting if one session cannot arm one repository twice.
//
// The first test here is 0043 F2's reproduction inverted. Against the tree
// before this landed it reports TWO watchers, two tokens and two slots; that
// is what makes it a check rather than a decoration.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/watch_settle.dart';

/// A live stream handle whose watcher never exits on its own, so a watcher
/// stays armed until it is torn down.
class _Handle implements CommandStreamHandle {
  final _out = StreamController<String>.broadcast();
  final _err = StreamController<String>.broadcast();
  var cancelled = false;

  void emit(String s) => _out.add(s);

  @override
  Stream<String> get stdout => _out.stream;
  @override
  Stream<String> get stderr => _err.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    await _out.close();
    await _err.close();
  }
}

/// Records every arm, so "how many watchers exist" is a number rather than an
/// inference.
class _ArmRecorder extends SSHCommandExecutor {
  _ArmRecorder() : super(SSHClientManager());

  final tokens = <String>[];
  final handles = <_Handle>[];

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
    tokens.add(
      RegExp(r'mg-watch\.(\w+)\.pid').firstMatch(gitArgs.join(' '))?[1] ?? '?',
    );
    final h = _Handle();
    handles.add(h);
    return h;
  }
}

void main() {
  setUp(RemoteWatchService.resetWatcherCount);
  tearDown(() async {
    await settleArm();
    RemoteWatchService.resetWatcherCount();
    watchDiagnostics.clear();
  });

  RemoteWatchService serviceOn(_ArmRecorder exec) =>
      RemoteWatchService(exec, hostKey: () => 'host', streamBudget: () => 8);

  test('two concurrent watchers of one path arm exactly once', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    final b = service.watch('/repo').listen((_) {});
    await settleArm();

    expect(
      exec.tokens,
      hasLength(1),
      reason:
          'the second caller must attach to the first watcher, not arm its '
          'own — two arms is 0043 F2, and the second one is what the host '
          'lock refuses',
    );
    expect(
      RemoteWatchService.liveWatchersFor('host'),
      1,
      reason:
          'a duplicate arm also consumes a second slot from the derived '
          'ceiling, which on a degraded session is the whole budget',
    );

    await a.cancel();
    await b.cancel();
  });

  test('both subscribers receive the same events', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final seenA = <WatchMode>[];
    final seenB = <WatchMode>[];
    final a = service.watch('/repo').listen((e) => seenA.add(e.mode));
    final b = service.watch('/repo').listen((e) => seenB.add(e.mode));
    await settleArm();

    expect(seenA, isNotEmpty, reason: 'the first subscriber sees the arm');
    expect(
      seenB,
      equals(seenA),
      reason: 'sharing a watcher means sharing its events, not just its cost',
    );

    await a.cancel();
    await b.cancel();
  });

  test('a late subscriber gets the current state without waiting', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    await settleArm();

    // Attaching to an already-armed, quiet repository. Without the retained
    // event this subscriber would have no mode at all until something
    // happened on the host — which on a quiet repo can be a long time.
    final late = <RepoWatchEvent>[];
    final b = service.watch('/repo').listen(late.add);
    await pumpEventQueue();

    expect(
      late,
      isNotEmpty,
      reason:
          'the most recent event is replayed to a subscriber that missed it',
    );
    expect(exec.tokens, hasLength(1), reason: 'and still only one watcher');

    await a.cancel();
    await b.cancel();
  });

  test('the watcher survives one subscriber leaving', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    final b = service.watch('/repo').listen((_) {});
    await settleArm();

    await a.cancel();
    await settleArm();

    expect(
      exec.handles.single.cancelled,
      isFalse,
      reason:
          'tearing down while another subscriber is still watching would take '
          'the watcher away from someone who never asked for that',
    );
    expect(RemoteWatchService.liveWatchersFor('host'), 1);

    await b.cancel();
  });

  test('the last subscriber leaving tears the watcher down', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    final b = service.watch('/repo').listen((_) {});
    await settleArm();

    await a.cancel();
    await b.cancel();
    await settleArm();

    expect(
      exec.handles.single.cancelled,
      isTrue,
      reason: 'nobody is listening, so the host must not keep a watcher',
    );
    expect(
      RemoteWatchService.liveWatchersFor('host'),
      0,
      reason: 'and the slot goes back',
    );
  });

  test('two different paths still get two watchers', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/one').listen((_) {});
    final b = service.watch('/two').listen((_) {});
    await settleArm();

    expect(
      exec.tokens,
      hasLength(2),
      reason: 'sharing is per PATH; different repositories are unrelated',
    );
    expect(RemoteWatchService.liveWatchersFor('host'), 2);

    await a.cancel();
    await b.cancel();
  });

  test(
    'two services on one path arm twice — sharing is per connection',
    () async {
      // Two tabs are two connections with two executors, and the host lock is
      // what arbitrates between them (MADR 0041 F12). Sharing them here would
      // hand one connection's watcher to another's session.
      final execA = _ArmRecorder();
      final execB = _ArmRecorder();

      final a = serviceOn(execA).watch('/repo').listen((_) {});
      final b = serviceOn(execB).watch('/repo').listen((_) {});
      await settleArm();

      expect(execA.tokens, hasLength(1));
      expect(
        execB.tokens,
        hasLength(1),
        reason:
            'a second SERVICE is a second session; it must still arm and still '
            'meet the host lock, which is the mechanism built for that case',
      );

      await a.cancel();
      await b.cancel();
    },
  );

  test('a stream that is never listened to arms nothing', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    service.watch('/repo'); // handed out, never subscribed
    await settleArm();

    expect(
      exec.tokens,
      isEmpty,
      reason:
          'building on first listen, not on the call, is what keeps an '
          'unused stream free',
    );
  });

  test('a rebuilt caller re-arms after the last subscriber left', () async {
    // The provider-rebuild shape: the old subscription goes, a new one
    // arrives. One watcher at a time, but a NEW one — the path is watched
    // again rather than left dead.
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    await settleArm();
    await a.cancel();
    await settleArm();

    final b = service.watch('/repo').listen((_) {});
    await settleArm();

    expect(exec.tokens, hasLength(2), reason: 'a second, distinct watcher');
    expect(
      exec.tokens.first,
      isNot(exec.tokens.last),
      reason: 'each watcher owns its own lease, per 0027',
    );
    expect(RemoteWatchService.liveWatchersFor('host'), 1);

    await b.cancel();
  });
}
