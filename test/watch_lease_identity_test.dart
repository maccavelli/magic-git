// MADR 0027 Phase 2: each watcher instance owns its own lease and registry
// files, so a live successor cannot hold a dead predecessor's lease open and
// the registry does not overwrite itself.

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

/// Records the watcher scripts it is asked to run, so a test can read the
/// lease-file paths the arm actually baked into them.
class _Recording extends SSHCommandExecutor {
  _Recording() : super(SSHClientManager());
  final scripts = <String>[];

  /// Ordered log of what the arm actually did on the host: `beat:<path>` when
  /// the client stamps a lease, 'arm:<script>' when it launches the watcher.
  final events = <String>[];

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
    scripts.add(joined);
    if (joined.contains('touch ')) events.add('beat:$joined');
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
  }) async {
    final joined = gitArgs.join(' ');
    scripts.add(joined);
    events.add('arm:$joined');
    return _Handle();
  }
}

/// Every `mg-watch.*` path mentioned in [scripts].
Set<String> leasePaths(List<String> scripts) {
  final re = RegExp(r'[\w/.\-]*mg-watch\.[\w.\-]+');
  return {for (final s in scripts) ...re.allMatches(s).map((m) => m[0]!)};
}

void main() {
  setUp(RemoteWatchService.resetWatcherCount);
  tearDown(RemoteWatchService.resetWatcherCount);

  test('two watcher instances own distinct lease files', () async {
    final exec = _Recording();
    final service = RemoteWatchService(exec);

    // Two instances for the SAME repo — the production case, where one is a
    // re-arm of the other and the older may outlive it as an orphan.
    final a = service.watch('/repo').listen((_) {});
    await pumpEventQueue();
    final afterFirst = leasePaths(exec.scripts);
    await a.cancel();

    final b = service.watch('/repo').listen((_) {});
    await pumpEventQueue();
    final all = leasePaths(exec.scripts);
    await b.cancel();

    expect(afterFirst, isNotEmpty, reason: 'the first arm names lease files');
    expect(
      all.length,
      greaterThan(afterFirst.length),
      reason:
          'the second instance must not reuse the first instance files; '
          'sharing them is what lets a live successor hold a dead '
          "predecessor's lease open (0027 defect 3)",
    );
  });

  test('a pid file and its heartbeat share one instance token', () {
    const gitDir = '/r/.git';
    final token = RemoteWatchService.newWatchToken();
    final pid = RemoteWatchService.watchPidFile(gitDir, token);
    final hb = RemoteWatchService.watchHeartbeatFile(gitDir, token);
    expect(pid, contains(token));
    expect(hb, contains(token));
    expect(pid, isNot(hb));
  });

  test('tokens are distinct across instances', () {
    final tokens = {
      for (var i = 0; i < 50; i++) RemoteWatchService.newWatchToken(),
    };
    expect(tokens, hasLength(50));
  });

  test('the lease exists before the watcher is armed', () async {
    // 0027 deviation (b). The lease loop's FIRST action is
    // `[ -f $hb ] || exit 0`. If the client stamps the heartbeat after
    // launching the script, the script loses the race and exits in ~5 ms —
    // every arm, because the tokenised filename can never pre-exist. The repo
    // then burns its restart budget and polls forever at 48 host processes a
    // minute.
    //
    // Neither half of this is wrong on its own, which is why testing the
    // halves missed it. This asserts the SEAM: the order of the two host
    // operations, and that they name the same instance.
    final exec = _Recording();
    final service = RemoteWatchService(exec);
    final sub = service.watch('/repo').listen((_) {});
    await pumpEventQueue();
    await sub.cancel();

    final beat = exec.events.indexWhere((e) => e.startsWith('beat:'));
    final arm = exec.events.indexWhere((e) => e.startsWith('arm:'));
    expect(beat, isNot(-1), reason: 'the client must stamp a lease at all');
    expect(arm, isNot(-1), reason: 'and it must arm a watcher');
    expect(
      beat,
      lessThan(arm),
      reason:
          'the lease must exist BEFORE the script checks for it; '
          'events were: ${exec.events.map((e) => e.split(':').first).toList()}',
    );

    // And it must be THIS instance's lease, not some other arm's.
    final token = RegExp(
      r'mg-watch\.(\w+)\.hb',
    ).firstMatch(exec.events[beat])?[1];
    expect(token, isNotNull, reason: 'the beat names a tokenised lease file');
    expect(
      exec.events[arm],
      contains(token!),
      reason: 'the armed script must check the lease the client just stamped',
    );
  });
}
