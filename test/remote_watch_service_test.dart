import 'dart:async';
import 'dart:math' show min;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor() : super(SSHClientManager());

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
    return const SSHCommandResult(exitCode: 0, stdout: 'none\n', stderr: '');
  }
}

/// Reports fswatch available, but fails every attempt to actually open the
/// streaming channel — exercises the "watcher tool detected but the channel
/// itself never comes up" path without needing a real, unmockable
/// SSHStreamHandle (its constructor is private).
class _ThrowingStreamExecutor extends SSHCommandExecutor {
  _ThrowingStreamExecutor() : super(SSHClientManager());

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
    return const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: '');
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
    throw Exception('cannot open watcher channel');
  }
}

/// A live-but-silent stream handle: the watcher channel opens fine and then
/// just never emits (no file changes). Lets a test hold the service in
/// event-driven mode.
class _SilentStreamHandle implements SSHStreamHandle {
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();

  @override
  Stream<String> get stdout => _stdout.stream;
  @override
  Stream<String> get stderr => _stderr.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    if (!_stdout.isClosed) await _stdout.close();
    if (!_stderr.isClosed) await _stderr.close();
  }
}

/// Reports no watcher tool on the first probe (degrading the service to
/// polling), then fswatch on every later probe with a working channel — the
/// "recovered from polling" path.
class _RecoveringExecutor extends SSHCommandExecutor {
  _RecoveringExecutor() : super(SSHClientManager());

  int probes = 0;

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
    final tool = probes++ == 0 ? 'none' : 'fswatch';
    return SSHCommandResult(exitCode: 0, stdout: '$tool\n', stderr: '');
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
    return _SilentStreamHandle();
  }
}

/// A stream handle the test drives directly — stdout and stderr both.
class _DrivableStreamHandle implements SSHStreamHandle {
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();

  /// Chunks handed to the service's listener so far. Delivery is one event per
  /// microtask and the listener body is synchronous, so once this reaches the
  /// number pushed, the last callback has run.
  int delivered = 0;

  void emitStdout(String chunk) {
    if (!_stdout.isClosed) _stdout.add(chunk);
  }

  void emitStderr(String chunk) {
    if (!_stderr.isClosed) _stderr.add(chunk);
  }

  @override
  Stream<String> get stdout => _stdout.stream.map((c) {
    delivered++;
    return c;
  });
  @override
  Stream<String> get stderr => _stderr.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    if (!_stdout.isClosed) await _stdout.close();
    if (!_stderr.isClosed) await _stderr.close();
  }
}

/// Reports [tool] and hands back a handle the test controls.
class _DrivableExecutor extends SSHCommandExecutor {
  _DrivableExecutor({required this.tool, required this.handle})
    : super(SSHClientManager());

  final String tool;
  final _DrivableStreamHandle handle;
  final armed = Completer<void>();

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
  }) async {
    if (!armed.isCompleted) armed.complete();
    return handle;
  }
}

/// The watcher probe fails once (a transport blip) and then reports fswatch.
/// Reading that failure as "this host has no watcher" is 0024 M3.
class _ProbeFailsOnceExecutor extends SSHCommandExecutor {
  _ProbeFailsOnceExecutor() : super(SSHClientManager());

  int probes = 0;

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
    // Exit 255 with empty stdout: what a dropped channel looks like. Today the
    // empty stdout falls through the switch to `none` and is cached.
    if (probes++ == 0) {
      return const SSHCommandResult(exitCode: 255, stdout: '', stderr: 'boom');
    }
    return const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => _SilentStreamHandle();
}

/// Hands out a FRESH handle per arm — the single-handle fake above cannot be
/// listened to twice, which would fail an arm for the wrong reason.
class _MultiArmExecutor extends SSHCommandExecutor {
  _MultiArmExecutor() : super(SSHClientManager());

  final handles = <_DrivableStreamHandle>[];

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
    final h = _DrivableStreamHandle();
    handles.add(h);
    return h;
  }
}

List<String> _chunk(String blob, int bytes) {
  final out = <String>[];
  for (var i = 0; i < blob.length; i += bytes) {
    out.add(blob.substring(i, min(i + bytes, blob.length)));
  }
  return out;
}

void main() {
  test('falls back to polling when no watcher tool is available', () {
    fakeAsync((async) {
      final service = RemoteWatchService(_FakeExecutor());
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch('/repo', pollInterval: const Duration(seconds: 5))
          .listen(events.add);

      async.elapse(Duration.zero);
      expect(events, isNotEmpty);
      expect(events.last.mode, WatchMode.polling);

      async.elapse(const Duration(seconds: 5));
      expect(events.length, greaterThanOrEqualTo(2));

      sub.cancel();
    });
  });

  test('recovering from polling back to event-driven stops the poll ticks '
      '(regression: the poll timer used to leak and fire forever)', () {
    fakeAsync((async) {
      final service = RemoteWatchService(_RecoveringExecutor());
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch(
            '/repo',
            pollInterval: const Duration(seconds: 5),
            recoveryInterval: const Duration(seconds: 30),
          )
          .listen(events.add);

      // First probe finds no tool → polling mode, ticking every 5s.
      async.elapse(Duration.zero);
      expect(events.last.mode, WatchMode.polling);
      async.elapse(const Duration(seconds: 29));
      expect(events.length, greaterThanOrEqualTo(5));

      // Recovery probe finds fswatch and the channel opens → event-driven.
      async.elapse(const Duration(seconds: 2));
      expect(events.last.mode, WatchMode.eventDriven);
      final atRecovery = events.length;

      // No file changes arrive; a leaked poll timer would keep emitting a
      // tick (each one a status round trip) every 5s regardless.
      async.elapse(const Duration(seconds: 60));
      expect(
        events.length,
        atRecovery,
        reason: 'poll timer must be cancelled once event-driven recovers',
      );

      sub.cancel();
    });
  });

  test('a failed watcher start surfaces `stopped` immediately, not silently '
      'through the whole restart backoff window', () {
    fakeAsync((async) {
      final service = RemoteWatchService(_ThrowingStreamExecutor());
      final events = <RepoWatchEvent>[];
      final sub = service.watch('/repo').listen(events.add);

      // The channel-open fails right away; before the fix, nothing was ever
      // emitted here — subscribers would see no event at all through the
      // entire restart backoff, previously indistinguishable from "still
      // fine" (whatever mode a consumer's UI last rendered).
      async.elapse(Duration.zero);
      expect(events, isNotEmpty);
      expect(events.last.mode, WatchMode.stopped);

      sub.cancel();
    });
  });

  test('inotifywait argv excludes git objects, logs, locks, and fsmonitor', () {
    final args = remoteWatcherArgs(RemoteWatcherTool.inotifywait, null);
    expect(args.take(2), ['sh', '-c']);
    final script = args.last;
    const excludes = [
      r"--exclude '/\.git/objects/'",
      r"--exclude '/\.git/logs/'",
      r"--exclude '\.lock$'",
      r"--exclude '/\.git/fsmonitor--daemon/'",
    ];
    for (final flag in excludes) {
      expect(script, contains(flag));
      expect(
        flag.allMatches(script),
        hasLength(2),
        reason: '$flag must appear on both the stdbuf and fallback arms',
      );
    }
    expect(
      script,
      contains(
        '-e modify,create,delete,move '
        r"--exclude '/\.git/objects/' "
        r"--exclude '/\.git/logs/' "
        r"--exclude '\.lock$' "
        r"--exclude '/\.git/fsmonitor--daemon/' "
        '--format',
      ),
    );
  });

  // ---- 0024 A1: the record split ----------------------------------------
  //
  // dartssh2 negotiates a 32 KiB maximum packet size (ssh_client.dart:57), so
  // that is the arrival shape these drive.
  group('record splitting', () {
    test('records straddling chunk boundaries survive intact', () async {
      // Well under 512 (watchLifecycle's maxPaths) so the burst stays
      // path-scoped instead of overflowing to an unscoped tick.
      final paths = [for (var i = 0; i < 60; i++) 'src/m$i/f$i.dart'];
      final handle = _DrivableStreamHandle();
      final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
      final service = RemoteWatchService(executor);

      final seen = <String>{};
      final sub = service.watch('/repo').listen((e) => seen.addAll(e.paths));
      await executor.armed.future;
      await Future<void>.delayed(Duration.zero);

      // Deliberately awkward: 37 bytes cuts records mid-path constantly.
      for (final c in _chunk('${paths.join('\n')}\n', 37)) {
        handle.emitStdout(c);
      }
      // Longer than the coalescer's 1s minInterval/maxWait, so the burst has
      // actually been emitted rather than still being batched.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // First, last, and a middle one — cheap assertions. `containsAll` over a
      // large set builds a pathological mismatch description when it fails.
      expect(seen, contains(paths.first));
      expect(seen, contains(paths[30]));
      expect(seen, contains(paths.last));
      expect(seen, hasLength(paths.length));
      await sub.cancel();
    });

    test('a large burst costs linear time, not a copy per record', () async {
      const records = 20000;
      final blob = [
        for (var i = 0; i < records; i++) 'src/m$i/f$i.dart',
      ].join('\n');
      final chunks = _chunk('$blob\n', 32 * 1024);

      final handle = _DrivableStreamHandle();
      final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
      final service = RemoteWatchService(executor);
      final sub = service.watch('/repo').listen((_) {});
      await executor.armed.future;
      await Future<void>.delayed(Duration.zero);

      final sw = Stopwatch()..start();
      for (final c in chunks) {
        handle.emitStdout(c);
      }
      while (handle.delivered < chunks.length) {
        await Future<void>.delayed(Duration.zero);
      }
      sw.stop();

      // Measured: re-slicing the buffer per record costs ~134 ms here; a
      // cursor costs ~1 ms. 50 ms sits ~2.7x under the quadratic cost and
      // ~50x over the linear one, so it cannot flake on a slow machine and
      // cannot pass on the old implementation.
      expect(
        sw.elapsedMilliseconds,
        lessThan(50),
        reason: 'splitting must not copy the remaining buffer per record',
      );
      await sub.cancel();
    });
  });

  // ---- 0024 H3: the watcher's stderr -------------------------------------
  group('watcher diagnostics', () {
    test('a diagnostic on stderr is surfaced, not discarded', () async {
      final handle = _DrivableStreamHandle();
      final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
      final diagnostics = <String>[];
      final service = RemoteWatchService(
        executor,
        onDiagnostic: diagnostics.add,
      );

      final sub = service.watch('/repo').listen((_) {});
      await executor.armed.future;
      await Future<void>.delayed(Duration.zero);

      // The one message that says WHY the watcher died, and names the knob.
      handle.emitStderr(
        'Failed to watch /home/u/src; upper limit on inotify watches reached\n',
      );
      await Future<void>.delayed(Duration.zero);

      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, contains('upper limit on inotify watches'));
      await sub.cancel();
    });

    test('a flooding watcher cannot fill the log', () async {
      // inotifywait prints one failure line per directory it cannot watch, so
      // a host at its watch limit emits one per entry in the surface.
      final handle = _DrivableStreamHandle();
      final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
      final diagnostics = <String>[];
      final service = RemoteWatchService(
        executor,
        onDiagnostic: diagnostics.add,
      );

      final sub = service.watch('/repo').listen((_) {});
      await executor.armed.future;
      await Future<void>.delayed(Duration.zero);

      for (var i = 0; i < 500; i++) {
        handle.emitStderr('Failed to watch /d$i\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(diagnostics, hasLength(RemoteWatchService.maxDiagnosticLines));
      await sub.cancel();
    });
  });

  // ---- 0024 M3: a failed probe is not "no watcher" ------------------------
  test('a failed watcher probe retries instead of caching "none"', () {
    fakeAsync((async) {
      final service = RemoteWatchService(_ProbeFailsOnceExecutor());
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch(
            '/repo',
            pollInterval: const Duration(seconds: 5),
            recoveryInterval: const Duration(minutes: 3),
          )
          .listen(events.add);

      async.elapse(Duration.zero);
      // Well inside the restart budget (2s, 4s, 6s) and far short of the
      // three-minute recovery probe that is the only other way back.
      async.elapse(const Duration(seconds: 10));

      expect(
        events.last.mode,
        WatchMode.eventDriven,
        reason: 'a transport blip must not cost three minutes of polling',
      );

      sub.cancel();
    });
  });

  group('watcher ceiling', () {
    test('the ceiling is a named constant', () {
      // One active repo plus one background. Beyond that, poll and say so.
      expect(RemoteWatchService.maxConcurrentWatchers, 2);
    });

    test(
      'arms past the ceiling degrade to polling with a diagnostic',
      () async {
        RemoteWatchService.resetWatcherCount();
        addTearDown(RemoteWatchService.resetWatcherCount);
        final exec = _MultiArmExecutor();
        final diagnostics = <String>[];
        final service = RemoteWatchService(exec, onDiagnostic: diagnostics.add);

        final subs = <StreamSubscription<RepoWatchEvent>>[];
        final modes = <int, List<WatchMode>>{};
        for (var i = 0; i <= RemoteWatchService.maxConcurrentWatchers; i++) {
          modes[i] = [];
          subs.add(
            service
                .watch('/r$i', pollInterval: const Duration(milliseconds: 50))
                .listen((e) => modes[i]!.add(e.mode)),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));

        // The arms within the ceiling are live; the one past it polls, and says
        // why — the failure mode that produced 19 orphans was accumulating in
        // silence instead.
        expect(
          modes[RemoteWatchService.maxConcurrentWatchers],
          contains(WatchMode.polling),
          reason: 'the arm past the ceiling must degrade, not accumulate',
        );
        expect(diagnostics.join(' '), contains('ceiling reached'));
        expect(exec.handles.length, RemoteWatchService.maxConcurrentWatchers);

        for (final sub in subs) {
          await sub.cancel();
        }
      },
    );
  });
}
